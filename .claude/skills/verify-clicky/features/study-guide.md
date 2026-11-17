# Notion study guide

While a YouTube video plays in Chrome's front tab, the learner asks for a study guide, and Clicky writes a Notion page about the video in the background while the video keeps playing.
`POST /study-guide` has Sonnet draft the guide from the captions and writes it as its own page in the Private section of the Notion user who made the token, with a timestamp link on every point and the quiz questions the learner missed or skipped listed first.
Clicky does not speak when the guide ends. A wingman triangle flies behind the blue cursor while it runs, and a finished guide opens in a Chrome tab behind the video tab, with a quiet chip under the cursor.
The learner can revise or open the guide by voice, and hold shift + option to see every agent and cancel one.

## Sub-features

- `guide-route` is `/study-guide`, which returns `{ pageHandle, pageURL, guide }` after creating the Notion page. It answers 400 before any model or Notion call for a video off youtube.com, its subdomains, and youtu.be, a transcript over 10,000 lines or 500,000 characters, a text field over 2,000 characters, or a handle over 200 characters.
- `guide-revise` sends `revision` with the previous page handle and guide, creates the new page, and trashes the old one.
  A handle the Worker did not sign gets a 400 before any model or Notion call.
- `guide-review-first` builds the "Review these first" section from the quiz results marked `missed` or `skipped`.
- `guide-not-connected` answers 503 when `NOTION_API_KEY` is missing, and the chip under the cursor says "Notion isn't connected yet" with a red outline wingman and no sound.
- `guide-voice-tools` offers `make_study_guide` with a YouTube video in front, no quiz question open, and no guide saved for that video, and `revise_study_guide` and `open_study_guide` once a guide is saved for it. The guide is saved under `savedStudyGuide.<video id>` in the app's defaults, so it outlives a relaunch, and `defaults delete com.crodris.clicky-watch-along savedStudyGuide.<video id>` makes the video writable again. Trashing the page in Notion does the same at the next voice command, since `POST /study-guide-status` then answers `{ "pageExists": false }` and the app logs `is no longer in Notion, so the saved guide is forgotten`.
- `guide-background` writes the guide in its own task, so a push-to-talk press does not cancel it, and nothing is spoken when it ends.
- `guide-wingman` shows an amber outline triangle behind the blue cursor triangle while the guide runs, filling by area through each step in step with the agent list's meter, and full with a green check mark after "Tink" and the amber chip "Study guide ready", with an amber triangle icon, when the page exists.
- `guide-agent-list` opens with a shift + option hold of 0.3 s, lists each agent with its subject, time, and steps, and cancels a running guide from its expanded row. Escape, a click outside, or the same hold closes it, and Chrome keeps the keyboard throughout.
  A key or a left, right, or middle mouse press during the hold breaks it, and so does a mouse button already down from a drag, so shift + option + drag in another app never opens the list.
- `guide-cancel-revision` keeps a cancelled revise or refresh whose reply already arrived, since the Worker already trashed the old page, and loads the new page in the old page's tab. A cancelled new guide keeps nothing.
- `guide-forgotten` forgets a saved guide whose page was trashed or deleted in Notion at its next status check, so `open_study_guide` fails with "This video's study guide was deleted in Notion" and `make_study_guide` is offered again. A guide being rewritten by a running guide agent is never forgotten.
- `guide-background-tab` opens the finished page as a new last tab of Chrome's front window, without switching away from the learner's tab.
- `guide-quiz-update` spawns a "Study guide update" wingman when a video quiz question on a video with a saved guide is missed or skipped, logs `Study guide: updating the guide with the quiz miss`, makes no Anthropic call for it, and the page's "Review these first" then lists the question. A miss while a guide is being written runs the refresh once that guide is written, only while that video is still in front, and never after a failure or a cancel; the app cuts quiz text to 2,000 UTF-16 units first. Earlier misses stay on the page after a relaunch, since each saved guide keeps the quiz results it was written with.
- `guide-team-theme` shows the agent as a team player when a school is picked: a round portrait (or the school's color with the player's initials when no portrait is bundled) in a ring in the school's color that fills clockwise, the player's name before the step line, the portrait as the ending chip's icon, and a themed row in the agent list with the school's name in its header. Clicky blue keeps the amber triangle.
- `guide-step-line` shows the running step beside the wingman closest to the blue triangle, such as "Reading the captions" and then "Writing the guide in Notion".
- `guide-open-tab` switches to that tab when the learner says "open my study guide", so Chrome holds one tab with the guide, and opens the page again only when that tab was closed. A revision's page loads in that same tab, and the chip says "· updated in its tab".

## How to get to it (user POV)

- Hold shift + option for a moment to open the agent list, click a row to see its steps, and press Cancel to stop a running guide.

- With a YouTube video in Chrome's front tab, hold ctrl+option and say "make me a Notion study guide for this".
- After the guide is ready, say "make the study guide shorter" or "open my study guide".
- During a video quiz, answer or skip a few questions first, then ask for the guide, and the missed ones come first.

## Driving it with verify-clicky.sh

Preconditions:

- `worker/.dev.vars` holds `NOTION_API_KEY`, a personal access token made at notion.so/developers, and `CLICKY_APP_SECRET`, which `$V post` sends in `x-clicky-app-secret` and `app-launch` copies into the app's defaults, both from `.dev.vars` without printing it.
- **Secret.** A curl to `/study-guide` without the header returns 401 and the Worker log has no Notion call.
  An internal connection's API token cannot create a page with no parent, so Notion rejects the create.
- For the app, the app and Chrome preconditions in [Video quiz](./video-quiz.md) apply, and the Debug build is newer than the last commit under `leanring-buddy/`.

- **Route.** Run `$V post /study-guide .claude/skills/verify-clicky/fixtures/study-guide.json`.
  The result is HTTP 200 with a `pageURL` on notion.so and a `guide` with 1 to 6 sections.
  The request takes about 20 to 60 seconds, and the Worker log has one `[/study-guide] usage` line per model attempt.
  The page id is the part of `pageHandle` before the last `.`.
  Read the page back with `GET https://api.notion.com/v1/blocks/<page id>/children` and the same token, and check the first heading is "Review these first".
- **Revise.** Post the fixture again with `revision` set to `{ pageHandle, previousGuide: guide, instruction: "make it shorter" }` from the first reply.
  The result is a new `pageHandle`, and `GET https://api.notion.com/v1/pages/<old page id>` shows `in_trash: true`.
  The same post with the handle's last character changed returns 400, and the Worker log has no new usage line.
- **Voice tools in the app.** With a YouTube video in front, run `$V app-launch "play the video"`, since `app-launch` refuses empty steps, then post `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"make_study_guide","arguments":{}}}` to `http://127.0.0.1:8790/mcp`.
  The app log shows `Study guide: wrote https://www.notion.so/... in N s`, and `tools/list` then includes `revise_study_guide` and `open_study_guide`.

- **Wingman.** With a YouTube video in front, post `make_study_guide` as above, then right away run `$V shot guide-running`.
  The screenshot shows an amber outline triangle down and to the right of the blue cursor triangle.
  After the app log shows `Study guide: wrote`, run `$V shot guide-done` within 4 seconds to see the amber triangle with a green check mark ahead of the tip and the "Study guide ready" chip.
- **Team theme.** Not run yet. Quit Clicky, run `defaults write com.crodris.clicky-watch-along companionTheme school:karasuno`, start it, post `make_study_guide`, and run `$V shot guide-themed`, then `$V key agents-list` and `$V shot guide-themed-list`.
  The wingman is Hinata's portrait in an orange ring with "Hinata" before the step line, and the list header says Karasuno with "on court". Delete the key to go back to Clicky blue.
- **Agent list.** While the guide runs, run `$V key agents-list`, then `$V shot guide-list`.
  The screenshot shows the "Agents" panel below and right of the mouse with a "1 running" header and a Study guide row.
  Run `$V key agents-list` again, or `$V key escape`, and a second `$V shot` shows it gone.
- **Agent list during a drag.** Needs the Accessibility grant (`Clicky start` logs `accessibility: true`).
  Close the list, start a 4 second drag in the background with `swift demo/scripts/mouse/mouse.swift drag 300 1000 330 1010 4 &`, wait 1.5 seconds, hold shift and option for 0.8 seconds through System Events (`key down shift`, `key down option`, `delay 0.8`), and run `$V shot drag-hold` before releasing them.
  The screenshot shows no "Agents" panel. It passed on 2026-11-16.
- **Trashed guide.** After a guide is written, trash its page with `PATCH https://api.notion.com/v1/pages/<page id>` and `{"in_trash":true}`, then post `tools/call` for `open_study_guide`.
  The result is an error saying the guide was deleted in Notion, the log shows `Study guide: <url> is no longer in Notion, so the saved guide is forgotten`, and `tools/list` offers `make_study_guide` again. It passed on 2026-11-16.
- **Background tab.** Before the guide ends, note the front tab with `osascript -e 'tell application "Google Chrome" to get URL of active tab of front window'`.
  After it ends, the same command prints the same URL, and `osascript -e 'tell application "Google Chrome" to get URL of last tab of front window'` prints the `notion.so` page.

## Gotchas

- A token from an internal connection ("API token" in the new connection dialog) fails the create, because only a token that acts as a user may create a page with no parent.
- Each route or app run creates a real private page, so trash the test pages afterwards.
- A handle is signed with the token itself, so a new token makes every earlier handle fail with 400. The app then forgets each saved guide at its next status check, so its video can get a new one.
- The Worker reads `.dev.vars` only when it starts, so restart it after changing the token.
- Notion API version `2026-03-11` trashes a page with `in_trash`, and the older `archived` field is rejected.
- YouTube can answer yt-dlp's caption download with HTTP 429 after several reads in a row, and the guide then fails with `yt-dlp exited with status 1`. Run yt-dlp by hand with the app's arguments to see the 429, and wait a few minutes or use a video whose captions are already read.
