# Video quiz

The learner asks Clicky to watch a YouTube video and quiz them.
Clicky reads the front Chrome tab, gets timestamped captions with yt-dlp, asks `/video-quiz-plan` which moments are worth a question, and pauses the video at each one.
Six seconds before each pause it grabs the frame, and when `/video-frame-parts` finds a subject, the subject lifts out in 3D before the question.
Saying "stop the quiz" ends it.

## Sub-features

- `quiz-start` starts on a sentence that names a video and asks to be quizzed.
  "Watch this with me" alone starts nothing.
- `quiz-plan` is the `/video-quiz-plan` route, which returns spread-out moments on transcript line boundaries, at least 20 seconds in.
- `quiz-pause` pauses at each moment, asks the question, and resumes after the answer.
- `quiz-stop` stops on "stop the quiz", "stop watching", or "can we stop".
  During a question it clears the pop-out first, and the video plays once the pop-out has landed in its frame.
- `quiz-skip` skips the current question on Escape, which `$V key escape` sends.

## How to get to it (user POV)

- Open a YouTube video in Chrome, hold ctrl+option, and say "watch this video with me and quiz me".
- Say "stop the quiz" to end it.

## Driving it with verify-clicky.sh

Preconditions:

- For the route, `$V worker-up` reported the Worker ready on port 8789.
- For the app, the app preconditions in [Live scene](./live-scene.md) apply.
- `yt-dlp` is installed at `/opt/homebrew/bin/yt-dlp` or `/usr/local/bin/yt-dlp`, the only two paths the app checks.
- Chrome's View > Developer > Allow JavaScript from Apple Events is on, and this build of Clicky has its Automation grant for Chrome.
  A first-use Automation prompt stalls an unattended run, so ask Chris to grant it first.
- Chrome's front tab is a YouTube video with captions, which `$V doctor` reports as "a YouTube video page".

- **Plan moments.** Run `$V post /video-quiz-plan .claude/skills/verify-clicky/fixtures/video-quiz-plan.json`.
  The result is HTTP 200 with `moments` in increasing `pauseAtSeconds` order, each at least 20 and each with a `question` and `answerLabel`.
- **Transcript cache.** Post the same body again within 5 minutes.
  The second usage line shows `cache_read_input_tokens` above 0.
  On the fixture it read 2246 cached tokens.
- **Cost ceiling.** At most 3 usage lines per request, since the route retries up to 2 times when a plan breaks a rule.
  Each line has `output_tokens` under 8000 and `thinking_tokens` above 0.
  Zero thinking means the effort setting was lowered, and low effort fails about half the plans even with the repair in `parseVideoQuizPlan`.
  On main after PR 3, 8 runs on 4 real transcripts returned 8 of 8 plans with 1 retry in total, averaging 2676 output tokens, 1524 thinking tokens, and 19.7 seconds per request.
- **Retries.** Each rejected attempt logs `[/video-quiz-plan] attempt N rejected: <reason>`, which `post` prints and saves to `<response>.rejections.log`.
  A request with 2 usage lines has 1 rejection line, and the report names the rule it gives.
  A pause between two transcript lines, a source time inside a line, or function words with capitals or spaces around them are repaired in code and never cause a rejection.
- **Quiz in the app.** Start the quiz and answer the first question.
  Run `$V app-launch "watch this video with me and quiz me|?I'm not sure, can you give me a hint|stop the quiz"` and `$V app-wait 600`.
  The log shows `Video quiz: found tab`, `read N caption lines`, `planned N moments`, `paused at Ns for moment 1`, then `Video quiz: stopped`.
- **Correct answer.** In a `?` step, `{answer}` becomes the open question's answer label, so `?is it the {answer}` answers correctly whatever the plan picked.
  The log shows the judge's grade, and a correct name turns the label green with the ring burst and the "Glass" sound.
- **Hidden labels.** On a video that prints its own labels, such as an anatomy animation, the log shows `Video quiz: hiding N printed text boxes until the pop-out returns` with N above 0.
  While the question and its follow-up are open, no printed word is readable on the frame or the lifted subject, even a tall title; after the pop-out returns to the video, the text is back.

## Gotchas

- The video plays in real time, so the first pause can be minutes away.
  Give `app-wait` enough seconds.
- YouTube can rate-limit this Mac's caption requests with HTTP 429 for an hour or more, and the quiz then fails at `read N caption lines`.
  Fetch the captions from another IP with yt-dlp (`--write-auto-subs --sub-langs en --sub-format json3`), save them as `<video id>.json3`, and run `defaults write <bundle id> debugVideoQuizCaptionsJSON3Path <that path>`.
  A Debug build then logs `Video quiz: reading captions from <path> instead of yt-dlp`, for the quiz and for find_moment. Run `defaults delete <bundle id> debugVideoQuizCaptionsJSON3Path` afterwards.
  The file counts only when its name holds the video's `v` parameter, so a youtu.be link never uses it.
  A file that does not apply logs `Video quiz: the debug captions file <path> does not apply to <url>`, and yt-dlp reads the captions instead.
  A file with no caption lines fails as no captions.
- A video without captions fails at `read N caption lines`.
  Pick another video, and do not report the route as broken.
- A `?` step waits at most 4 minutes for a question to be asked.
  A later first moment makes the step time out and answer nothing.
- The quiz pauses and resumes the video only when its tab is in front.
  Do not switch tabs during the run.
