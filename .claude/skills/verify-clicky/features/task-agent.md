# Task agent

While a video plays, the learner hands Clicky any task that needs more than a quick answer, and a general background agent works on it while the video keeps playing.
It searches the web, reads the video's captions and looks at the video, can write a Notion page, and reports each step in the agent list, with a teal-ringed token beside the notch.
When it finishes, its page opens in a background tab, and the chip says "Task done · say what did you find". Clicky speaks the answer only when asked.

## Sub-features

- `task-harness` is the Go helper `harness/`, bundled as `Contents/Helpers/clicky-agent-harness`, which runs the agent's loop with Sonnet 5.5, web search, web fetch, and the app's tools. It talks to the app in JSON lines on stdin and stdout.
- `task-route` is the Worker's `/v1/messages` passthrough, which the harness's Anthropic SDK calls. It forwards the body and the stream unchanged and needs the app secret.
- `task-page` is `/notion-page`, which writes a private page with a summary, sections, and linked sources, and returns `{ pageURL }`.
- `task-router` sends "find out", "look up", "research", and "compare" requests to `start_background_task`, and "what did you find" to `hear_task_answer`, which the router takes until the answer is heard, even with no video in front.
- `task-steps` shows each `report_step` as the list's checklist.
- `task-page-check` keeps a `/notion-page` reply only when its `pageURL` is an https page on Notion (`taskAgentNotionPageURL`), since "Open page" in the agent list hands it to NSWorkspace, which opens any URL scheme.
- `task-skills` runs a skill from `leanring-buddy/Skills/` or `~/Library/Application Support/Clicky/Skills/` when `start_task` carries a `skill` name, and fails the task with a reason for a missing or malformed one.
- `task-skill-router` lists the skills in the router's `start_background_task` tool and passes the skill the model picks to `start_task`. The router side is checked by `node bench/brainEvals.ts run` (cases `video-flashcards`, `video-research-no-skill`, and the other skill cases), and the app side by `TaskAgentSkillsTests`.
- `task-general-tools` are `take_screenshot`, `read_clipboard`, `write_clipboard`, and `open_url`, which the app runs.
- `task-mcp` offers the tools of the servers in `~/Library/Application Support/Clicky/mcp.json` as `mcp__<server>__<tool>`.
- `task-approvals` asks the app before a tool with a capability runs (`sends`, `deletes`, `spends`, `reads_private`). The app holds the request until the learner answers it with the Yes, Always, or No button in the agent list, or by voice with `answer_approval`, and declines it after 120 seconds.
- `task-ending` plays "Tink", opens the page behind the video tab, and shows the teal chip, and `hear_task_answer` speaks the answer.
  The finished agent's token stays beside the notch, with a green check, until the answer is heard or 10 minutes pass. Opening its page keeps the token. Its list row offers "Hear answer" and "Open page", and "Hear answer" waits while a video quiz question is open.

## How to get to it (user POV)

- With a video in Chrome's front tab, hold ctrl+option and say "find out how this catch compares to the first booster catch, and make me a Notion page about it".
- Hold shift + option, flick to Agents, and let go to see its steps.
- When the chip says "say what did you find", say "what did you find".

## Driving it with verify-clicky.sh

Preconditions:

- A Worker this run started on 8787 or 8789, and `worker/.dev.vars` with `NOTION_API_KEY` for the page and `CLICKY_APP_SECRET`, which `/v1/messages` and `/notion-page` require.
- Go, for the app's "Build Agent Harness" build phase and for `cd harness && go test ./...`.
- **Cost ceiling.** The Worker no longer logs usage for these turns, so the harness logs one `Task agent: turn N stopped for ..., tokens in ..., out ...` line per turn into the app log. A task ends within 14 turns. A take that compared two booster catches and wrote a page took 4 turns.

- **Harness loop.** Build the harness with `cd harness && go build -o /tmp/clicky-agent-harness .`, then run it with `CLICKY_WORKER_BASE_URL=http://127.0.0.1:8787 CLICKY_APP_SECRET=<the secret> /tmp/clicky-agent-harness`, and write `{"type":"start_task","taskID":"t1","goal":"...","frontTabTitle":null,"frontTabURL":null}` to its stdin.
  It answers with `tool_call` lines for `report_step`, `read_video_captions`, `look_at_video`, and `write_notion_page`, and you reply to each with `{"type":"tool_result","taskID":"t1","toolUseID":"...","content":"shown","isError":false}`.
  The loop ends on a `task_finished` or `task_failed` line, within a few turns, and every line it writes is JSON.
  Post a `write_notion_page` input to `/notion-page` and the reply holds a `notion.com` `pageURL`.
- **In the app.** Run `$V app-launch "play the video"` with a YouTube video in front, then post `tools/call` for `start_background_task` with `{"goal":"find out how this compares to the first booster catch, and make me a Notion page about it"}` to `http://127.0.0.1:8790/mcp`.
  The app log shows `Task agent: finished in N s after M turns`, `Task agent: wrote https://...`, and a teal-ringed token floats beside the notch meanwhile, with the reported steps in the agent list.
  Post `tools/call` for `hear_task_answer`, and Clicky speaks the answer.

- **Approvals.** `take_screenshot`, `read_clipboard`, `write_clipboard`, `open_url`, and every MCP tool wait for the learner, since a tool that says it is read only reads private data.
  The app log shows `Agent harness: approval <id> requested for <capability>`, "Pop" plays, and the agent list opens next to the mouse, at a corner that does not cover the pointer.
  An approval card pinned under the list's header shows the whole summary and the buttons Yes, Always, and No, the agent's row says "Needs your OK", and the chip says "<agent> needs your OK · say yes or no".
  A click, or a spoken yes, counts only once the card has shown the whole summary, from top to bottom, for 1 second, so a click within that second logs `ignored a click on approval`.
  A summary taller than 200 points scrolls, but this check needs one taller than 400 points, since the top range (0 to 200) and the bottom range of a shorter one overlap and the jump alone would count as whole. With the mouse over the summary, a jump straight to its end (`$V scroll 2000`) leaves the middle unseen, so a click still logs `ignored a click on approval`. Then scroll back up through the middle with several `$V scroll -80` calls, or return to the top with `$V scroll -2000` and step down with `$V scroll 80` calls, wait 1 second, and the click logs `given (once)`.
  Click a button, and the log shows `Agent harness: approval approval-1 given (once)` or `declined`, and the tool runs or comes back as "The learner declined this action". Always lets that tool run again with no question until the harness stops.
  By voice, hold ctrl+option and say "yes", "no", or "always allow it". In a Debug app launched by `verify-clicky.sh app-launch` (which passes `--voice-tool-debug-server`), post `tools/call` for `answer_approval` with `{"approved":true,"always":false}` to `http://127.0.0.1:8790/mcp`. The tool is listed only while a request waits.
  Post `tools/call` for `debug_answer_approval` with `{"approvalID":"approval-1","approved":true,"scope":"once"}` to answer one request by its ID, such as the second of two waiting requests.
  Two requests wait in arrival order. The list shows the oldest with its buttons, the other row says "Needs your OK after the one above", and an answer moves on to the next. An unanswered request is declined after 120 seconds, with `timed out` in the log.
  The router's `scene_state` holds only `approvalWaiting` with the capability word. Check the Worker log with the "Log tool call JSON" switch on that the summary text never appears in the request.
  To drive the harness alone, answer each `approval_request` line with `{"type":"approval_result","approvalID":"approval-1","approved":true,"scope":"once"}`.
- **Skills.** Send `start_task` with `"skill":"flashcards"` and `CLICKY_SKILLS_DIRS=<repo>/leanring-buddy/Skills`. The first request's tools are only `report_step`, `read_video_captions`, `look_at_video`, `take_screenshot`, `web_fetch`, `write_notion_page`, and `finish`. A skill name with no file ends in `task_failed` with `no skill named`.
- **MCP.** Set `CLICKY_MCP_CONFIG` to an `mcp.json` such as `{"mcpServers":{"t3-code":{"type":"http","url":"http://127.0.0.1:3773/mcp","headers":{"Authorization":"Bearer <token>"}}}}`, and the harness logs `MCP: 1 server(s) connected, offering N tool(s)` when the first task starts. T3 Code's MCP endpoint refuses a request with no bearer credential.

## Gotchas

- Every turn sends the whole history again, fetched pages included, so web fetch cuts pages to 8,000 tokens.
- Each page run creates a real private Notion page, so trash the test pages afterwards.
- The agent's spoken answer and page come from web pages, which are untrusted, so the app cuts the answer to 600 characters and the Worker checks the page input.
- `look_at_video` returns only the video's area, captured from Chrome's windows, and an error when no video is found, so an injected page cannot make the agent read the rest of the screen.
- `take_screenshot` and `read_clipboard` can read anything, and `open_url` and `write_clipboard` can send data out or plant text, so each needs the learner's approval in code (`reads_private` or `sends`). A page that talks the agent into them is stopped at the approval, and the summary shows the whole link, with its host in Punycode, or the whole clipboard text.
- A clipboard write over 500 characters and an MCP input over 1,500 characters are refused with no approval request, so the learner is never asked about text they cannot read in full.
- A server's tool descriptions and results are text the server wrote, so the agent reads them as data, and a server's annotations are its own claims.
