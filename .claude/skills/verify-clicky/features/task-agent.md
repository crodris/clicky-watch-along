# Task agent

While a video plays, the learner hands Clicky any task that needs more than a quick answer, and a general background agent works on it while the video keeps playing.
It searches the web, reads the video's captions and looks at the video, can write a Notion page, and reports each step beside a teal wingman.
When it finishes, its page opens in a background tab, and the chip says "Task done · say what did you find". Clicky speaks the answer only when asked.

## Sub-features

- `task-route` is `/background-agent`, one turn with Sonnet 5.5, web search, web fetch, and the app's tools, which returns every content block and the stop reason.
- `task-page` is `/notion-page`, which writes a private page with a summary, sections, and linked sources, and returns `{ pageURL }`.
- `task-router` sends "find out", "look up", "research", and "compare" requests to `start_background_task`, and "what did you find" to `hear_task_answer`.
- `task-steps` shows each `report_step` on the wingman's line and as the list's checklist.
- `task-ending` plays "Tink", opens the page behind the video tab, and shows the teal chip, and `hear_task_answer` speaks the answer.

## How to get to it (user POV)

- With a video in Chrome's front tab, hold ctrl+option and say "find out how this catch compares to the first booster catch, and make me a Notion page about it".
- Hold shift + option to see its steps.
- When the chip says "say what did you find", say "what did you find".

## Driving it with verify-clicky.sh

Preconditions:

- A Worker this run started on 8787 or 8789, and `worker/.dev.vars` with `NOTION_API_KEY` for the page and `CLICKY_APP_SECRET`, which `/background-agent` and `/notion-page` require.
- **Cost ceiling.** One `[/background-agent]` usage line per turn, and a task ends within 14 turns. A take that compared two booster catches and wrote a page took 4 turns.

- **Route loop.** Post a first turn to `/background-agent` with `{ messages: [{ role: "user", content: "Task from the learner: ..." }], tools: [...] }`, the tools being `TaskAgentTool`'s descriptors, and keep posting with the reply's `content` appended as the assistant turn and a `tool_result` for each `tool_use`.
  The replies hold `server_tool_use` blocks for `web_search`, and the loop ends on a `finish` call within a few turns.
  Post a `write_notion_page` input to `/notion-page` and the reply holds a `notion.com` `pageURL`.
- **In the app.** Run `$V app-launch "play the video"` with a YouTube video in front, then post `tools/call` for `start_background_task` with `{"goal":"find out how this compares to the first booster catch, and make me a Notion page about it"}` to `http://127.0.0.1:8790/mcp`.
  The app log shows `Task agent: finished in N s after M turns`, `Task agent: wrote https://...`, and a teal wingman shows the reported steps meanwhile.
  Post `tools/call` for `hear_task_answer`, and Clicky speaks the answer.

## Gotchas

- Every turn sends the whole history again, fetched pages included, so web fetch cuts pages to 8,000 tokens.
- Each page run creates a real private Notion page, so trash the test pages afterwards.
- The agent's spoken answer and page come from web pages, which are untrusted, so the app cuts the answer to 600 characters and the Worker checks the page input.
- `look_at_video` returns only the video's area, captured from Chrome's windows, and an error when no video is found, so an injected page cannot make the agent read the rest of the screen.
