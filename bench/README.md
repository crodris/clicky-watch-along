# Clicky benchmark

`bench.ts` measures the latency, tokens, and cost of every Worker route the demo uses, and checks each reply for quality on fixed fixtures.
It runs on top of the `verify-clicky` skill, which starts and stops the local Worker and keeps its log.
Results are JSON files in `results/`, named `<label>-<kind>-<commit>.json`.
A result whose `workingTreeIsDirty` is true was recorded with uncommitted changes, so the commit in its name does not fully reproduce it.

## Run it

Run every command from the checkout root.
A worker run sends real requests with the Worker's API keys, so estimate its cost first.
At 5 runs per case it costs about $1.60 without the simulation cases, and the GPT live scene is $1.15 of that.
The five `simulation-*` cases are GPT live scenes too, at about $0.37 each, so they add about $9 at 5 runs.
When a change does not touch the simulation prompt, list the other case IDs in `--only` to skip them.

```bash
V=.claude/skills/verify-clicky/verify-clicky.sh
(cd bench && pnpm install)
$V new-run bench
$V worker-up
node bench/bench.ts worker --label baseline --runs 5
$V cleanup
```

`--only chat-first,tts` limits the run to some cases.
`--pages-dir <dir>` saves every full reply as `<side>-<case>-<run>.json` and each case's request once as `requests/<case>.json`, since the sample's `replyPreview` stops at 600 characters.
A `/live-scene` page is also saved as `<side>-<case>-<run>.html`, so the pages can be rendered and compared.
`judge.ts` reads these files.
Case IDs are the `id` fields in `benchCases`.

## Compare two commits

Run the two Workers side by side and let the benchmark alternate between them, so drift in upstream latency hits both sides equally.
Each side is `label:port:checkout`.
Each side sends what its own app version sends: the benchmark reads the chat model, effort, system prompt, whether the system prompt carries a cache breakpoint, the speech model, and the speech format from that checkout's Swift source, and prints them as the side's app profile.
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
- `firstAudioMs` is when the app could start speaking a `/tts` reply: the first buffer of streamed PCM, or the whole body for an MP3, which the older app downloads in full before it plays. A PCM line shorter than one buffer is timed at the end of its stream.
- Tokens come from the Worker's `[/route] usage {...}` log lines, one per model call, so two lines for one request mean one retry.
  Streamed `/chat` logs no usage line, so its tokens come from the stream's `message_start` and `message_delta` events.
- `costUSD` prices each usage line by the model it names. `/tts` is priced per character. A GPT call is priced per token at the standard prices in `usage.ts`, times the tier OpenAI reported (Ultrafast is 6 times standard), and the case summary lists the tiers in `serviceTiers`. The GPT prices are estimates, since OpenAI's pricing page refuses automated fetches, and `gpt-6-luna`'s price is a guess. A model or tier with no price, or a model route that answered without a usage line, records `costUSD` as null and prints a warning, so the run goes on, and the case's mean cost is then null too.
- `quality` is a per-case check of the reply, such as the pointer landing on a "Download PDF" control or the landmark within 0.003 degrees of the Eiffel Tower.

## Model bakeoff runbook

This runs each Worker route on Claude models and GPT-6 models, and picks the best model per route on the fixed fixtures.
`/live-scene` is not part of it.
Every command here runs from the checkout root, in zsh.

A Worker started with `--var BENCH_MODEL:<model>` runs its model routes and `/chat` on that model (see `worker/src/benchModelOverride.ts`).
A `claude-*` model swaps the model in the request.
A `gpt-*` model gets the request mapped to the OpenAI Responses API, and its reply and its `/chat` stream are mapped back.
`BENCH_EFFORT` replaces the route's effort, and `BENCH_SERVICE_TIER` sets the OpenAI tier.
Without `BENCH_MODEL` the Worker behaves as it always did, and `wrangler.toml` never sets it.
`/v1/messages`, which serves the agent harness, never uses it.
Each Worker holds one model, so the run starts one Worker per model and gives each its own port.

### Before you start

- This checkout needs `worker/.dev.vars` with `ANTHROPIC_API_KEY` and `OPENAI_API_KEY`. Run the `worktree-setup` skill first in a fresh worktree.
- Ports 8791 to 8798 must be free, and `worker-up` refuses a busy one. Port 8787 belongs to the app's Worker, and port 8790 to the app's debug tool server, so no Worker here uses either.
- Chrome must be at `/Applications/Google Chrome.app`, or set `CHROME_PATH`, since the judge draws each reply in headless Chrome.
- Nobody needs to use the Mac, but the Workers spend the API keys for any local caller until `$V cleanup` stops them.
- OpenAI's GPT-6 model IDs were checked against its free model list on 2026-11-19: `gpt-6-luna`, `gpt-6-sol`, `gpt-6.1-sol`, `gpt-6-astra`, `gpt-6.2-astra`, `gpt-6.2-sol`, and `gpt-6.1-terra` exist.
- The prices for `gpt-6-luna`, `gpt-6-sol`, and `gpt-6-astra` in `bench/usage.ts` are assumptions. Check them before you trust a cost comparison that includes them.
- Gemini 4 Neon (`gemini-4-neon`) needs `GEMINI_API_KEY` in `worker/.dev.vars`. Create it at https://aistudio.google.com/apikey with billing on, since Neon has no free tier. Its Worker line is `$V worker-up 8798 -- --inspector-port 9308 --var BENCH_MODEL:gemini-4-neon`, and it takes no `BENCH_SERVICE_TIER`. The Worker calls Google's OpenAI-compatible endpoint, which cannot turn thinking off, so `/voice-command` gets `low` effort. Priced at $3 input, $0.15 cached input, and $15 output per million tokens.

```bash
V=.claude/skills/verify-clicky/verify-clicky.sh
C="$PWD"
b() { node bench/bench.ts worker --pages-dir bench/replies "$@"; }
(cd bench && pnpm install) && $V new-run bench
```

### Start the Workers

A Worker that never becomes ready usually has a wrong `BENCH_` var.
Run `curl -s -X POST http://127.0.0.1:<port>/judge-answer -d '{}'` to read its message.
Each Worker gets its own inspector port, since wrangler fails when two share one.

```bash
$V worker-up 8791 -- --inspector-port 9301
$V worker-up 8792 -- --inspector-port 9302 --var BENCH_MODEL:claude-haiku-5-5
$V worker-up 8793 -- --inspector-port 9303 --var BENCH_MODEL:claude-sonnet-5-5
$V worker-up 8794 -- --inspector-port 9304 --var BENCH_MODEL:claude-opus-5-5
$V worker-up 8795 -- --inspector-port 9305 --var BENCH_MODEL:gpt-6-luna --var BENCH_SERVICE_TIER:ultrafast
$V worker-up 8796 -- --inspector-port 9306 --var BENCH_MODEL:gpt-6-sol --var BENCH_SERVICE_TIER:ultrafast
$V worker-up 8797 -- --inspector-port 9307 --var BENCH_MODEL:gpt-6.1-sol --var BENCH_SERVICE_TIER:ultrafast
$V worker-up 8798 -- --inspector-port 9308 --var BENCH_MODEL:gpt-6.2-astra
```

| Port | Side name | Model | Tier |
|---|---|---|---|
| 8791 | `base` | the model each route uses today | as the route sends |
| 8792 | `haiku` | `claude-haiku-5-5` | |
| 8793 | `sonnet` | `claude-sonnet-5-5` | |
| 8794 | `opus` | `claude-opus-5-5` | |
| 8795 | `luna` | `gpt-6-luna` | Ultrafast |
| 8796 | `sol` | `gpt-6-sol` | Ultrafast |
| 8797 | `sol61` | `gpt-6.1-sol` | Ultrafast |
| 8798 | `astra` | `gpt-6.2-astra` | standard |

The plan named `gpt-6-astra`.
Both IDs exist, so the table uses the newer one.
Swap the var to `gpt-6-astra` to run the older one.
Ultrafast costs 6 times standard, so every printed model carries its tier.
If a model refuses the tier, the smoke test shows an HTTP 400.
Drop `BENCH_SERVICE_TIER` for that Worker and say so next to its numbers.

### Smoke test

This sends one run of five cheap cases to every side, for about $0.60.
It shows a refused tier or effort, a strict schema error, a missing price, and a broken stream before any real money goes out.
It saves no replies.
Every side should print PASS, or a FAIL whose detail is the model's own wrong answer.
An `HTTP 400` or `HTTP 501` line names what the port could not do.
`cost unknown` means the model has no price in `usage.ts`.

```bash
node bench/bench.ts worker --label smoke --runs 1 --only judge-correct,voice-command,chat-first,landmark,frame-parts-heart \
  --side smoke-base:8791:$C --side smoke-haiku:8792:$C --side smoke-sonnet:8793:$C --side smoke-opus:8794:$C \
  --side smoke-luna:8795:$C --side smoke-sol:8796:$C --side smoke-sol61:8797:$C --side smoke-astra:8798:$C
rm bench/results/smoke-*
```

### The runs

Each command interleaves its sides request by request, so drift in upstream latency hits every side equally.
Run them in this order, which is the order of user impact, with `/chat` last because its GPT port translates a stream.
The side names must be `<group>-<name>`, with `base` as the baseline, since `judge.ts` pairs on them.

```bash
b --label judge --runs 5 --only judge-correct,judge-named-only,judge-wrong,judge-help,judge-function-only,judge-caption-supported,judge-caption-wrong,judge-hint,judge-skip,judge-repeat,judge-scene-command \
  --side judge-base:8791:$C --side judge-haiku:8792:$C --side judge-luna:8795:$C --side judge-sol:8796:$C
b --label voice --runs 5 --only voice-command,voice-command-seek,voice-command-zoom,voice-command-explain,voice-command-no-tool \
  --side voice-base:8791:$C --side voice-sonnet:8793:$C --side voice-luna:8795:$C
b --label quiz --runs 3 --only video-quiz-plan,video-quiz-plan-long \
  --side quiz-base:8791:$C --side quiz-opus:8794:$C --side quiz-luna:8795:$C --side quiz-sol61:8797:$C
b --label parts --runs 3 --only frame-parts-heart,frame-parts-painting,frame-parts-cutaway,frame-parts-print,frame-parts-art-of-one-animal,frame-parts-bicycle,frame-parts-chart \
  --side parts-base:8791:$C --side parts-opus:8794:$C --side parts-sol:8796:$C --side parts-sol61:8797:$C
b --label chat --runs 5 --only chat-first,chat-followup \
  --side chat-base:8791:$C --side chat-haiku:8792:$C --side chat-luna:8795:$C --side chat-sol:8796:$C
b --label flows --runs 3 --only picture-flows-heart,picture-flows-water-cycle,picture-flows-cutaway,picture-flows-bicycle \
  --side flows-base:8791:$C --side flows-sonnet:8793:$C --side flows-sol61:8797:$C --side flows-astra:8798:$C
b --label landmark --runs 5 --only landmark,landmark-not-a-place \
  --side landmark-base:8791:$C --side landmark-haiku:8792:$C --side landmark-luna:8795:$C
```

| Route | Baseline today | Challengers | Quality check |
|---|---|---|---|
| `/judge-answer` | Sonnet 5.5, low effort | Haiku 5.5, Luna, Sol | pass counts |
| `/voice-command` | Haiku 5.5, low effort, thinking off | Sonnet 5.5, Luna | pass counts |
| `/video-quiz-plan` | Sonnet 5.5 | Opus 5.5, Luna, 6.1 Sol | blind judge |
| `/video-frame-parts` | Sonnet 5.5, low effort | Opus 5.5, Sol, 6.1 Sol | blind judge |
| `/chat` | Sonnet 5.5, low effort | Haiku 5.5, Luna, Sol | blind judge |
| `/picture-flows` | Opus 5.5, low effort | Sonnet 5.5, 6.1 Sol, Astra | blind judge |
| `/landmark` | Sonnet 5.5, low effort | Haiku 5.5, Luna | pass counts |

`/voice-command` sends thinking off, so a GPT model gets the lowest reasoning effort it accepts: `none`, else `minimal`, else `low`.
The Worker finds it from the first 400 and remembers it, so only the first call of a run is slower.
`/chat` gives a GPT model the same 1,024 output tokens, and a GPT model counts its reasoning inside them.
A `/chat` reply with no `[POINT]` tag and a short, cut-off text means the reasoning used the limit, not that the model failed to point.

### The blind judge

The pass counts cannot see whether a frame's parts sit on the right places, whether a flow follows the picture, or whether a quiz plan asks good questions.
`judge.ts` scores those four routes.
It pairs the baseline's saved reply with each challenger's reply to the same case and run, and draws each reply over its frame in headless Chrome, with the model names left out.
It asks Opus 5.5 and GPT-6.1 Sol which reply is better, with the replies in both A/B orders.
A win counts only when a judge picks the same reply in both orders.
Two judges from two vendors offset a judge that favors its own family.
It reports each judge's decided share, since a judge that follows position decides few pairs.
It saves each judgment as it arrives, so a run that stops can be run again without paying twice.

```bash
node bench/judge.ts --replies bench/replies --dry-run
node bench/judge.ts --replies bench/replies
open bench/replies/judged/spotcheck.html
```

The dry run draws the replies and writes the spot-check page for $0, and prints the pair count.
It pairs the first run of each case by default, which is about 45 pairs and 180 judging calls for the runs above.
`--pairs-per-case 3` judges every run, for three times the calls.
`--judges opus` or `--judges sol` uses one judge, `--routes /chat` limits the routes, and `--effort high` raises the judges' effort.
The page shows 10 pairs across the routes with the sides hidden.
Pick a winner for each before you open its reveal, and compare with the judges.
The tallies are in `bench/replies/judged/summary.json`, and every judgment with its reason is in `judgments.json`.

### The decision rule

This rule was written before the runs.
Switch a route to a challenger only when all of these hold:

- Its pass count is at least the baseline's on every case.
- Its cost per call is at most 3 times the baseline's, or under $0.01.
- One of these holds. The p50 total time is at least 25% lower and the p95 is no worse. Or the blind win rate is at least 60% and the p50 is within 10%.

A blind win rate is the challenger's wins over its decided calls, counted from `summary.json`.
Only the routes judged blind can use the second arm.
`/judge-answer`, `/voice-command`, and `/landmark` can only use the first, and their pass counts are the quality check.
A gap smaller than the run-to-run range counts as no difference.
Every prompt was tuned for Claude, so a GPT model that comes within one pass, or 10%, of the winner gets one rerun with a prompt tuned for it.
A GPT model that comes close at one effort also gets a rerun at the next effort, by adding `--var BENCH_EFFORT:medium` to its Worker.
OpenAI resizes images differently, so a coordinate that is off for a GPT model may be the port and not the model.
OpenAI caches prompts over 1,024 tokens on its own, and the first run is cold on every side.

### Cost and time

These are estimates from committed token counts, with Sol at $2 in and $10 out, Astra at $8 and $40, and Luna at a guessed $0.5 and $2, all times 6 for Ultrafast.

| Step | Calls per side | Challenger cost | Time |
|---|---|---|---|
| Setup, eight Workers, and the smoke test | 5 | about $0.60 | about 10 minutes |
| `/judge-answer` | 11 cases x 5 = 55 | about $1.40 | about 15 minutes |
| `/voice-command` | 5 x 5 = 25 | about $0.60 | about 5 minutes |
| `/video-quiz-plan` | 2 x 3 = 6 | about $2.20 | about 15 minutes |
| `/video-frame-parts` | 7 x 3 = 21 | about $2.40 | about 8 minutes |
| `/chat` | 2 x 5 = 10 | about $0.60 | about 3 minutes |
| `/picture-flows` | 4 x 3 = 12 | about $1.80 | about 6 minutes |
| `/landmark` | 2 x 5 = 10 | under $0.30 | about 2 minutes |
| The blind judge | about 180 calls | about $4 | about 15 minutes |

The total is about $14 and 80 minutes, plus the baseline side of every run, which costs what the app costs today.

### When it ends

```bash
$V cleanup
```

`cleanup` stops every Worker, which holds the API keys.
The results are in `bench/results/<side>-worker-<commit>.json`, which you can commit.
`node bench/report.ts --out /tmp/clicky-report bench/results/<label>-*.json` turns them into CSV tables with a `service_tiers` column.
`bench/replies/` holds every full reply and is not committed.
