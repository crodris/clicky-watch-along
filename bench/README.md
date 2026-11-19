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

This runs every Worker route that calls a model on each lab's flagship models, and compares each with `base`, the model the route uses today, on the fixed fixtures.
The challengers are Claude Haiku 5.5, Sonnet 5.5, Opus 5.5, and Fable 5.2, GPT-6.2 Sol and GPT-6.2 Astra, and Gemini 4 Neon.
A `/live-scene` render costs about $0.40, so the runbook records only its baseline on GPT-6.1 Sol, and runs challengers on it only when asked.
Every command here runs from the checkout root, in zsh.

A Worker started with `--var BENCH_MODEL:<model>` runs its model routes and `/chat` on that model (see `worker/src/benchModelOverride.ts`).
A `claude-*` model swaps the model in the request.
A `gpt-*` model gets the request mapped to the OpenAI Responses API, and its reply and its `/chat` stream are mapped back.
`BENCH_EFFORT` replaces the route's effort, and `BENCH_SERVICE_TIER` sets the OpenAI tier.
Without `BENCH_MODEL` the Worker behaves as it always did, and `wrangler.toml` never sets it.
`/v1/messages`, which serves the agent harness, runs on a `claude-*` model and answers a 501 to any other, since the task agent uses Anthropic's server-side web search.
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
Start the Neon Worker only when `worker/.dev.vars` has `GEMINI_API_KEY`.

```bash
$V worker-up 8791 -- --inspector-port 9301
$V worker-up 8792 -- --inspector-port 9302 --var BENCH_MODEL:claude-haiku-5-5
$V worker-up 8793 -- --inspector-port 9303 --var BENCH_MODEL:claude-sonnet-5-5
$V worker-up 8794 -- --inspector-port 9304 --var BENCH_MODEL:claude-opus-5-5
$V worker-up 8795 -- --inspector-port 9305 --var BENCH_MODEL:claude-fable-5-2
$V worker-up 8796 -- --inspector-port 9306 --var BENCH_MODEL:gpt-6.2-sol --var BENCH_SERVICE_TIER:ultrafast
$V worker-up 8797 -- --inspector-port 9307 --var BENCH_MODEL:gpt-6.2-astra --var BENCH_SERVICE_TIER:ultrafast
$V worker-up 8798 -- --inspector-port 9308 --var BENCH_MODEL:gemini-4-neon
```

| Port | Side name | Model | Tier |
|---|---|---|---|
| 8791 | `base` | the model each route uses today | as the route sends |
| 8792 | `haiku` | `claude-haiku-5-5` | |
| 8793 | `sonnet` | `claude-sonnet-5-5` | |
| 8794 | `opus` | `claude-opus-5-5` | |
| 8795 | `fable` | `claude-fable-5-2` | |
| 8796 | `sol62` | `gpt-6.2-sol` | Ultrafast |
| 8797 | `astra` | `gpt-6.2-astra` | Ultrafast |
| 8798 | `neon` | `gemini-4-neon` | |

The app sends GPT-6.1 Sol renders at Ultrafast, so the GPT challengers run at Ultrafast too, which costs 6 times standard.
Both GPT-6.2 models accepted it on 2026-11-19.
Sonnet 5.5, Opus 5.5, and Fable 5.2 cannot turn thinking off, so on `/voice-command`, which turns it off for Haiku, they run at the route's low effort with thinking on.

```bash
sides() { local g=$1; print -- --side $g-base:8791:$C --side $g-haiku:8792:$C --side $g-sonnet:8793:$C --side $g-opus:8794:$C \
  --side $g-fable:8795:$C --side $g-sol62:8796:$C --side $g-astra:8797:$C; }
# With the Neon Worker up, add: --side $g-neon:8798:$C
```

### Smoke test

This sends one run of one case per route to every side, for about $2.
It shows a refused tier or effort, a strict schema error, a missing price, and a broken stream before the real runs.
Every side should print PASS, or a FAIL whose detail is the model's own wrong answer.
An `HTTP 400` or `HTTP 501` line names what the port could not do.
`cost unknown` means the model has no price in `usage.ts`.

```bash
node bench/bench.ts worker --runs 1 --only judge-correct,voice-command,chat-first,landmark,frame-parts-heart,video-quiz-plan,picture-flows-heart ${=$(sides smoke)}
rm bench/results/smoke-*
```

### The runs

Each command interleaves its sides request by request, so drift in upstream latency hits every side equally.
The side names must be `<group>-<name>`, with `base` as the baseline, since `judge.ts` pairs on them.
The four groups below can run at the same time, which takes about 45 minutes instead of about 2 hours.
They share each Worker's log, and `bench.ts` keeps only the usage lines of the route a call measured, so the costs stay apart.

```bash
b() { local label=$1; shift; node bench/bench.ts worker --pages-dir bench/replies --label $label "$@" ${=$(sides $label)}; }
{ b judge --runs 5 --only judge-correct,judge-named-only,judge-wrong,judge-help,judge-function-only,judge-caption-supported,judge-caption-wrong,judge-hint,judge-skip,judge-repeat,judge-scene-command
  b landmark --runs 5 --only landmark,landmark-not-a-place } > /tmp/bench-a.txt 2>&1 &
{ b voice --runs 5 --only voice-command,voice-command-seek,voice-command-zoom,voice-command-explain,voice-command-no-tool
  b chat --runs 5 --only chat-first,chat-followup } > /tmp/bench-b.txt 2>&1 &
{ b parts --runs 3 --only frame-parts-heart,frame-parts-painting,frame-parts-cutaway,frame-parts-print,frame-parts-art-of-one-animal,frame-parts-bicycle,frame-parts-chart
  b flows --runs 3 --only picture-flows-heart,picture-flows-water-cycle,picture-flows-cutaway,picture-flows-bicycle } > /tmp/bench-c.txt 2>&1 &
b quiz --runs 3 --only video-quiz-plan,video-quiz-plan-long > /tmp/bench-d.txt 2>&1 &
wait
```

| Route | Baseline today | Quality check |
|---|---|---|
| `/judge-answer` | Sonnet 5.5, low effort | pass counts |
| `/voice-command` | Haiku 5.5, low effort, thinking off | pass counts |
| `/video-quiz-plan` | GPT-6.2 Sol Ultrafast, OpenAI's default effort (Sonnet 5.5 before 2026-11-19) | pass counts and the blind judge |
| `/video-frame-parts` | Sonnet 5.5, low effort | pass counts and the blind judge |
| `/chat` | Sonnet 5.5, low effort | pass counts and the blind judge |
| `/picture-flows` | Sonnet 5.5, low effort (Opus 5.5 before 2026-11-19) | pass counts and the blind judge |
| `/landmark` | Sonnet 5.5, low effort | pass counts |
| `/live-scene` | GPT-6.1 Sol Ultrafast, medium effort | baseline only, below |
| task agent (`/v1/messages`) | Sonnet 5.5, medium effort | `taskAgent.ts`, below |

`/voice-command` sends thinking off, so a GPT model gets the lowest reasoning effort it accepts: `none`, else `minimal`, else `low`.
The Worker finds it from the first 400 and remembers it, so only the first call of a run is slower.
`/chat` gives a GPT model the same 1,024 output tokens, and a GPT model counts its reasoning inside them.
A `/chat` reply with no `[POINT]` tag and a short, cut-off text means the reasoning used the limit, not that the model failed to point.
`/chat` streams, so its table's `ttft` column is the time to the first text token. Every other route answers in one JSON reply, so its first byte is its whole answer.

The render baseline records what GPT-6.1 Sol does today, so a later challenger run has numbers to beat.

```bash
node bench/bench.ts worker --pages-dir bench/replies --label render --runs 3 --only live-scene,simulation-projectile,simulation-lever --side render-base:8791:$C
```

To run a challenger on renders later, add its side, such as `--side render-sol62:8796:$C`, to that command.
Each render call costs about $0.40 on GPT-6.1 Sol Ultrafast.

### Task agent

The task agent is the one model call `bench.ts` does not cover, because its loop runs in the Go harness, which talks to the Worker's `POST /v1/messages` passthrough.
`taskAgent.ts` runs the built harness against Workers that each run the agent on one Claude model.
GPT and Gemini cannot run it, since it uses Anthropic's server-side web search and the harness speaks the Anthropic API.

Build the harness once. It runs against the Claude Workers above.

```bash
(cd harness && go build -o ../bench/.harness/clicky-agent-harness .)
node bench/taskAgent.ts --harness bench/.harness/clicky-agent-harness --label agent --runs 2 \
  --side base:8791 --side haiku:8792 --side sonnet:8793 --side opus:8794 --side fable:8795
```

It runs 3 goals that need web search and no Chrome, once per run per side, one task at a time, with the sides alternating run by run.
The app's tools answer as in the app where they can: `report_step` shows, `read_video_captions` and `look_at_video` say no video is open, and `write_notion_page` says Notion is off, so no Notion page is written.
Each run records total time, time to the first `tool_call` or `log` line (the end of the first turn, not the first token), turns, tokens, cost, and the spoken answer.
Time is read over finished runs only, and tokens and cost over every run.
Cost counts tokens only, at the prices in `usage.ts`, so web search fees are not in it.
The harness does not log its model or its web search count, so the model comes from the side name (`base` and `sonnet` are Sonnet 5.5), or from `name:port:model`.

Results go to `bench/results/<label>-<side>-task-agent-<sha>.json`, and each full answer to `bench/replies/task-agent/<side>-<task>-<run>.json`, so the answers can be read side by side.
The Worker logs the model each call used, so `wrangler tail` on a side confirms that its override applied.

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
It pairs the first run of each case by default, which is 89 pairs and 356 judging calls for the runs above with six challengers.
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

### Graphics

`bench/graphics/` holds five 1600 by 900 cards of the 2026-11-19 results, for posting.
`node bench/bakeoffGraphics.ts` reads the committed results into `bench/graphics/bakeoff-data.js`, and `bench/graphics/render.sh` draws each card to a PNG with headless Chrome.
The blind judge's tallies are copied into `bakeoffGraphics.ts`, since `bench/replies/` is gitignored.

### Cost and time

Measured on 2026-11-19 with base and the six challengers other than Neon.

| Step | Calls per side | Cost, all seven sides | Time |
|---|---|---|---|
| Setup, seven Workers, and the smoke test | 7 | about $2 | about 10 minutes |
| The four groups, run at once | 139 | about $15, of which Astra is $9 | about 45 minutes |
| The render baseline | 9 | about $3.70 | about 4 minutes |
| The task agent, four Claude sides | 6 | about $3 | about 15 minutes |
| The blind judge | 356 calls | about $8 | about 20 minutes |

Neon, run on its own beside base on 2026-11-19, cost about $3.50 and took about 50 minutes, since its long quiz plans each waited out the 5 minute timeout.

### When it ends

```bash
$V cleanup
```

`cleanup` stops every Worker, which holds the API keys.
The results are in `bench/results/<side>-worker-<commit>.json`, which you can commit.
`node bench/report.ts --out /tmp/clicky-report bench/results/<label>-*.json` turns them into CSV tables with a `service_tiers` column.
`bench/replies/` holds every full reply and is not committed.
