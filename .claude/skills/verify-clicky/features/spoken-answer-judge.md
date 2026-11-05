# Spoken-answer judge

After a quiz question, the learner answers out loud and Clicky grades the answer as correct, named only, wrong, or a request for help, then says one sentence back.
The Worker's `/judge-answer` route asks Sonnet for the verdict and the sentence.
If that call fails, the app falls back to its own word match.

## Sub-features

- `judge-correct` grades an answer that names the part and what it does as `correct`.
- `judge-named-only` grades an answer that names the part but not what it does as `named_only`, which earns one follow-up question in the app.
- `judge-wrong` grades a wrong part as `wrong`.
- `judge-help` grades "I don't know" or "give me a hint" as `asked_for_help`.

## How to get to it (user POV)

- Answer a live scene quiz question out loud after the camera tour ends.
- Answer a video quiz question out loud while the video is paused.

## Driving it with verify-clicky.sh

Preconditions:

- `$V worker-up` reported the Worker ready on port 8789.

- **Correct answer.** The learner names the left ventricle and says it pumps blood to the body. Run `$V post /judge-answer .claude/skills/verify-clicky/fixtures/judge-answer.json`. HTTP 200, `"verdict":"correct"`, and a non-empty `spokenReply`.
- **Other verdicts.** Copy the fixture into the run folder and change only `transcript`: "it's the left ventricle" for `named_only`, "that's the aorta" for `wrong`, "I have no idea, can you help" for `asked_for_help`. Post each the same way. Each returns its verdict.
- **Cost ceiling.** Each request prints exactly one usage line with `thinking_tokens` 0 and `output_tokens` under 300. On main it used 46 to 60 output tokens over 20 calls. Thinking tokens above 0 mean the low-effort setting was dropped.
- **In the app.** Answer through a live scene quiz with a `?` step, as in [Live scene](./live-scene.md). The app log shows no `Live scene answer judge failed` line, and Clicky speaks the judge's sentence.

## Gotchas

- A 400 with a Zod message means the body is missing `question`, `answerLabel`, `explanation`, or `transcript`. The free doctor probe relies on exactly that 400, so a 400 is not a model failure.
- Clicky's own word match covers a failed judge call, so a spoken grade in the app does not prove the Worker route ran. Check for the usage line or the absence of the `answer judge failed` log line.
- `heardTranscript` is optional and capped at 8000 characters.
