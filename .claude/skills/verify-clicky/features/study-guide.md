# Notion study guide

While a YouTube video plays in Chrome's front tab, the learner asks for a study guide, and Clicky writes a Notion page about the video in the background while the video keeps playing.
`POST /study-guide` has Sonnet draft the guide from the captions and writes it under the parent page the Notion connection can see, with a timestamp link on every point and the quiz questions the learner missed or skipped listed first.
Clicky says "Your study guide is ready in Notion." when the page exists, and the learner can revise or open it by voice.

## Sub-features

- `guide-route` is `/study-guide`, which returns `{ pageId, pageURL, guide }` after creating the Notion page.
- `guide-revise` sends `revision` with the previous page and guide, creates the new page, and trashes the old one.
- `guide-review-first` builds the "Review these first" section from the quiz results marked `missed` or `skipped`.
- `guide-not-connected` answers 503 when `NOTION_API_KEY` or `NOTION_STUDY_GUIDE_PARENT_PAGE_ID` is missing, and Clicky says "Notion isn't connected yet."
- `guide-voice-tools` offers `make_study_guide` with a YouTube video in front and no quiz question open, and `revise_study_guide` and `open_study_guide` once a guide exists for that video.
- `guide-background` writes the guide in its own task, so a push-to-talk press does not cancel it, and the finished line waits until Clicky is quiet and no quiz question is open.

## How to get to it (user POV)

- With a YouTube video in Chrome's front tab, hold ctrl+option and say "make me a Notion study guide for this".
- After the guide is ready, say "make the study guide shorter" or "open my study guide".
- During a video quiz, answer or skip a few questions first, then ask for the guide, and the missed ones come first.

## Driving it with verify-clicky.sh

Preconditions:

- `worker/.dev.vars` holds `NOTION_API_KEY` and `NOTION_STUDY_GUIDE_PARENT_PAGE_ID`, and the parent page is shared with the connection (on the page, open the ... menu, then Connections).
- For the app, the app and Chrome preconditions in [Video quiz](./video-quiz.md) apply, and the Debug build is newer than the last commit under `leanring-buddy/`.

- **Route.** Run `$V post /study-guide .claude/skills/verify-clicky/fixtures/study-guide.json`.
  The result is HTTP 200 with a `pageURL` on notion.so and a `guide` with 1 to 6 sections.
  The request takes about 20 to 60 seconds, and the Worker log has one `[/study-guide] usage` line per model attempt.
  Read the page back with `GET https://api.notion.com/v1/blocks/<pageId>/children` and the same token, and check the first heading is "Review these first".
- **Revise.** Post the fixture again with `revision` set to `{ pageId, previousGuide: guide, instruction: "make it shorter" }` from the first reply.
  The result is a new `pageId`, and `GET https://api.notion.com/v1/pages/<old pageId>` shows `in_trash: true`.
- **Voice tools in the app.** With a YouTube video in front, run `$V app-launch ""`, then post `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"make_study_guide","arguments":{}}}` to `http://127.0.0.1:8790/mcp`.
  The app log shows `Study guide: wrote https://www.notion.so/... in N s`, and `tools/list` then includes `revise_study_guide` and `open_study_guide`.

## Gotchas

- A Notion connection sees only pages shared with it, so a search that returns 0 pages means the parent page was never shared.
- Each route or app run creates a real page under the parent page, so trash the test pages afterwards.
- The Worker reads `.dev.vars` only when it starts, so restart it after adding the Notion values.
- Notion API version `2026-03-11` trashes a page with `in_trash`, and the older `archived` field is rejected.
