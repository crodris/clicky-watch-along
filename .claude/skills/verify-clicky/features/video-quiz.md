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
- `quiz-skip` skips the current question on Escape, which this skill cannot drive.

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
  Report the retry count.
  Each line has `output_tokens` under 8000 and `thinking_tokens` above 0.
  Zero thinking means the effort setting was lowered, and plans then fail the rules most of the time.
  On main, 8 runs on 4 real transcripts averaged 4164 output tokens with 2659 thinking, and 4 of the 8 retried once.
- **Quiz in the app.** Start the quiz and answer the first question.
  Run `$V app-launch "watch this video with me and quiz me|?I'm not sure, can you give me a hint|stop the quiz"` and `$V app-wait 600`.
  The log shows `Video quiz: found tab`, `read N caption lines`, `planned N moments`, `paused at Ns for moment 1`, then `Video quiz: stopped`.

## Gotchas

- The video plays in real time, so the first pause can be minutes away.
  Give `app-wait` enough seconds.
- A video without captions fails at `read N caption lines`.
  Pick another video, and do not report the route as broken.
- A `?` step waits at most 4 minutes for a question to be asked.
  A later first moment makes the step time out and answer nothing.
- The quiz pauses and resumes the video only when its tab is in front.
  Do not switch tabs during the run.
