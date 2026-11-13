# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it with Apple Speech (this fork's provider; AssemblyAI streaming and OpenAI are the alternatives), and sends the transcript + a screenshot of the user's screen to Claude. Claude responds with text (streamed via SSE) and voice (ElevenLabs TTS). A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 4.6 default, Opus 4.6 optional) via Cloudflare Worker proxy with SSE streaming
- **Speech-to-Text**: Apple Speech, selected by `VoiceTranscriptionProvider` = `apple` in Info.plist. Setting it to `assemblyai` (real-time streaming over a websocket, `u3-rt-pro` model) or `openai` (upload on release) switches providers
- **Text-to-Speech**: ElevenLabs (`eleven_multilingual_v2` model) via Cloudflare Worker proxy
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS audio |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetches a short-lived (480s) AssemblyAI websocket token |
| `POST /live-scene` | `api.openai.com/v1/responses` | GPT-6.1 Sol Ultrafast writes a three.js page and a quiz from the question and screenshot |
| `POST /judge-answer` | `api.anthropic.com/v1/messages` | Sonnet grades a spoken answer as correct, named only, wrong, or a request for help |
| `POST /video-quiz-plan` | `api.anthropic.com/v1/messages` | Sonnet reads a video's timestamped transcript once, decides how many moments are worth a question, and picks them. Returns `{ moments: [{ pauseAtSeconds, sourceLineSeconds, question, answerLabel, functionWords, explanation, subject }] }`. Each moment lands on a transcript line boundary, at least 20 seconds in, and the moments are spread across the video |
| `POST /video-frame-parts` | `api.anthropic.com/v1/messages` | Sonnet finds the subject in a frame grabbed from the playing video, or a screen capture of a page image, and places up to 8 part labels, dropping any label that is not a short plain name. Returns `{ subjectFound, subjectBox, wholePictureIsSubject, parts: [{ label, x, y, isQuizAnswer }] }` in frame pixels, or `{ subjectFound: false }` for a chart or a person talking. `wholePictureIsSubject` is true for a painted scene, such as a landscape, and its box covers the whole painting |
| `POST /landmark` | `api.anthropic.com/v1/messages` | Sonnet says whether a paused frame shows one famous real place, and returns `{ isFamousPlace, name, latitude, longitude, heightMeters, radiusMeters }` |
| `GET /v1/3dtiles/...` | `tile.googleapis.com` | Google Photorealistic 3D Tiles for the landmark page. Only `root.json` and dataset files pass, and the Worker adds `GOOGLE_MAPS_API_KEY` |

Worker secrets: `ANTHROPIC_API_KEY`, `ELEVENLABS_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_MAPS_API_KEY` (a Maps Platform key with the Map Tiles API enabled and billing linked), and `ASSEMBLYAI_API_KEY` only when Info.plist selects the `assemblyai` provider
Worker vars: `ELEVENLABS_VOICE_ID`, and optional `LIVE_SCENE_MODEL` (`gpt` by default, or `sonnet`)

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

**Live Scene**: A transcript that contains "inside", "look like", "show me", "3D", or "render" calls `POST /live-scene`, and every label stays visible.
`POST /live-scene` asks GPT-6.1 Sol Ultrafast (`gpt-6.1-sol`, service tier `ultrafast`) for a self-contained three.js page and a quiz.
The page builds the whole subject from the outside, and adds the parts inside, fading the outer shell, only when the learner asks to see inside.
The page imports three.js only from `clicky-asset://three/three.module.js`, which the overlay serves from the app bundle.
The overlay serves the generated page from `clicky-asset://live/page.html` with a Content-Security-Policy header, a content rule blocks http, https, ws, and wss, and navigation is limited to `about` and `clicky-asset`.
On a timeout, an error, or a 422, Clicky says "Sorry, I couldn't build that one." and resumes a video it paused for the scene.
A transcript that says "quiz" or "test me" plays the same scene with one label shown as "?".
The overlay plays a generated scene on the screen under the mouse cursor.
A frame pop-out or landmark page plays on the screen showing its video or image instead, so it lines up even when the mouse is on another display.
The page rises out of the video or image it was asked about: Clicky reads the on-screen rect of the largest visible video or image in Chrome's front tab before the request, skipping images that show nothing (not loaded, hidden, or fully transparent), and places the rect from the web area in Chrome's accessibility tree, with the page-geometry math as the fallback when no web area matches, and `LiveSceneRise.swift` adds the cursor screenshot and that rect to the page for the bundled `scene-rise.js`, which shows the screenshot clipped to the rect and grows the page out of it once the scene is ready.
In a quiz, Clicky asks what that part is and what it does when the camera tour ends, and a correct name that misses what it does gets one follow-up.
The learner answers by voice.
`POST /judge-answer` asks Sonnet to grade that answer as correct, named only, wrong, or a request for help, and returns one spoken sentence.
If the judge call fails, the app falls back to the word match in `LiveSceneAnswerJudge`.
A finished scene stays above every window until Escape clears it.
During a video quiz question, Escape skips the question, clears its pop-out, and plays the video on.
When the tour ends the overlay catches the mouse, a drag orbits the camera around the last stop, and a trackpad pinch zooms it.
The overlay never becomes key, so the pinch comes from the push-to-talk event tap, not AppKit.
The overlay is a nonactivating panel, so the page under it keeps the keyboard.
Before any public release, add a runtime block for WebRTC in dynamically created frames, add authentication and rate limits to the Worker (the `GET /v1/3dtiles/` route spends the Maps key for any caller), send video captions to /live-scene as a separate untrusted field instead of merging them into the learner's request, and pass part labels read from a generated page as sanitized untrusted data instead of putting them in the system prompt.

**Video Quiz**: A voice request to watch a video and be quizzed starts `VideoQuizSession`: it reads the YouTube tab through AppleScript, gets timestamped captions with yt-dlp, asks `POST /video-quiz-plan` for the moments, and pauses at each one through JavaScript in Chrome. Saying only "watch this with me" starts nothing. Saying "stop the quiz" (or end, cancel, quit, or "done with the quiz") stops it, along with "stop quizzing", "stop watching", and "can we stop" or "let's stop" when speech recognition drops the last word. Push-to-talk keeps the microphone on for half a second after the shortcut is released, so the last word is not cut off, and Apple Speech gets Clicky's command phrases as contextual strings. While Clicky reads the captions and plans, the status label says "Reading the transcript" and then "Picking spots to quiz you on". A scene or pop-out asked for during a quiz pauses and resumes the quiz video only when its tab is the one in front. Six seconds before each pause, while the video plays, it grabs the frame from the `<video>` element through JavaScript and asks `POST /video-frame-parts` for the subject and its labels. At the pause it uses that early grab when it found a subject, because the pop-out covers the video with its own frame. It grabs the paused frame only when the early grab found nothing or never ran. When a subject was found, `frame-popout.html` lifts it out of the frame in 3D, starting exactly over the video on screen, and Clicky asks the question when that tour ends. Otherwise the question is voice only. The pop-out clears before the video plays again. Saying "pop this out" (or "pop out", or up to 3 words between, as in "pop this heart out") lifts the subject of the frame the YouTube tab shows right now out in 3D with every label and no question, using the same frame grab, `POST /video-frame-parts`, and `frame-popout.html`; during a video quiz it pauses the video first. When Chrome's front tab is not a YouTube video, it lifts the largest visible video or image on the page instead. Apple's subject lifting cuts the subject out of the frame. A painted scene, such as The Starry Night, is the exception: `POST /video-frame-parts` returns `wholePictureIsSubject: true`, and the painting lifts out whole, sky included, because subject lifting would keep only the cypress. Art that shows one animal or object on a plain background, such as Dürer's Young Hare, still lifts out only the animal. Clicky captures the screen under it at the display's pixel density, up to 1280 pixels on the longest side, showing only Chrome's windows, because a page canvas cannot read an image served from another site. When "show me" or "render this in 3D" is said over a YouTube frame that `POST /landmark` recognizes as a famous place, `landmark-tiles.html` shows Google's real 3D scan of it instead, cut down to the structure and about 130 m of its surroundings and floating over the video. The overlay fetches the tiles from `clicky-asset://tiles/`, which the asset handler forwards to the Worker, so the page never holds the key or reaches the network, and only this bundled page gets the policy that allows its WebAssembly Draco decoder. A 3D model built from scratch appears only on request: "show me" or "in 3D" pauses the video and builds one from what the video just said, and clearing it resumes the video.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~98 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window. The app lives entirely in the status bar. |
| `LiveSceneOverlay.swift` | ~550 | Reusable transparent window and page on the screen it is given: the mouse screen for generated scenes, the screen showing the video or image for pop-outs and landmark pages. Serves the generated page and bundled three.js at `clicky-asset`, blocks network requests, reveals the quiz label, and clears the scene. |
| `LiveSceneSession.swift` | ~185 | Live scene phase, scene kind, quiz, spoken-answer judge, the transcript trigger that picks explore, quiz, or frame pop-out, and the `[PART:label]` splitter for spoken replies. |
| `VideoQuizSession.swift` | ~950 | Voice command, Chrome tab finder, yt-dlp caption reader, and the session that pauses a YouTube video at each planned moment. Talks to Chrome through AppleScript, posts the transcript to `POST /video-quiz-plan`, and grabs each moment's frame while the video plays. |
| `LiveSceneStatusLabel.swift` | ~160 | Label next to the cursor while Clicky pops something out, builds a scene, or plans a video quiz. It takes a `LiveSceneStatusLine`, leaves the view tree when hidden so its loop stops, and runs the loop at 30 frames a second (paused with Reduce Motion). Each owner (pop-out, scene build, video quiz) hides only its own lines with `hide(onlyIfShowingOneOf:)`, and a delayed swap uses `replace(_:with:)` so a line never returns after a push-to-talk press hid the label. It publishes whether the screen's edge moved the panel off the triangle's spot. Clicky also says "Building your 3D scene" and "Almost there" out loud. |
| `LiveSceneStatusLine.swift` | ~330 | The six status lines, each with its own `DS.Colors` palette and looping letter animation, the sets of lines each owner may hide, and the pop-out cube's pose. The math takes a time and returns a pose, so tests check it without drawing. |
| `LiveSceneStatusLabelViews.swift` | ~470 | Draws a status line: an animated icon on a white tile (drawn in a `Canvas`), then letters with a white outline. |
| `VideoFramePopout.swift` | ~365 | The grabbed frame, the `POST /video-frame-parts` client, and the pop-out page built from the bundled `LiveSceneAssets/frame-popout.html` template with the video rect moved into the overlay screen's coordinates. Its `screenRectInChromeCoordinates(from:backingScaleFactor:)` is the fallback that places a page element from the window and page geometry when `ChromeWebArea.swift` finds no web area. |
| `ChromeWebArea.swift` | ~140 | Reads the screen frame of the page viewport from the web area in Chrome's accessibility tree (the Accessibility permission Clicky already has), and picks the web area that matches the page's shape to place the image rect, which holds with side panels, vertical tabs, or docked DevTools in the window. Turning on Chrome's accessibility tree keeps it on for the rest of Chrome's session, which costs Chrome some CPU and memory. |
| `LiveSceneRise.swift` | ~50 | Loads the bundled `LiveSceneAssets/scene-rise.js` and adds it, with the cursor screenshot and the media rect, before the last `</body>` of a generated page. |
| `LiveSceneAssets/scene-rise.js` | ~90 | Runs after a generated page's body. Shows the screenshot clipped to the media rect, shrinks the body onto that rect, then lifts it to full screen over 1.6 seconds once `window.__ready` is true or after 1.5 seconds. |
| `LandmarkTiles.swift` | ~105 | The `POST /landmark` client and the landmark page built from `LiveSceneAssets/landmark-tiles.html`. `three-tiles.js` and the Draco decoder in `LiveSceneAssets` are built by `tools/three-tiles` (`pnpm install && pnpm run build`). |
| `LiveSceneClient.swift` | ~180 | Posts the cursor screen JPEG to `POST /live-scene`, and posts a spoken answer to `POST /judge-answer`. |
| `CompanionManager.swift` | ~1700 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the push-to-talk pipeline, the live scene, the video quiz, and the spoken-answer judge. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~761 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Sonnet/Opus), permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~895 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Hides the triangle, spinner, and waveform while a status line shows, the buddy follows the cursor, and the icon sits on the triangle's spot. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~236 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display, and captures one page image's screen rect (Chrome's windows only, at the display's pixel density, up to 1280 pixels on the longest side) for the image pop-out. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeAPI.swift` | ~291 | Claude vision API client with streaming (SSE) and non-streaming modes. TLS warmup optimization, image MIME detection, conversation history support. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | ~81 | ElevenLabs TTS client. Sends text to the Worker proxy, plays back audio via `AVAudioPlayer`. Exposes `isPlaying` for transient cursor scheduling. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~920 | Design system tokens — colors (including the status line palettes), corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `leanring-buddyTests/leanring_buddyTests.swift` | ~415 | Swift Testing unit tests for voice-command parsing, quiz grading, the live scene trigger and rise script, the image pop-out's rect and screen choice, the status label's animation and line ownership, and the permission gate. They import `Clicky` and run on the main actor, hosted in `Clicky.app`. |
| `worker/src/index.ts` | ~165 | Cloudflare Worker proxy. Routes: `/chat` (Claude), `/tts` (ElevenLabs), `/transcribe-token` (AssemblyAI temp token), `/live-scene` (generated page), `/judge-answer` (spoken grade), `/video-quiz-plan` (video quiz moments), `/video-frame-parts` (subject and labels in a frame). |
| `worker/src/videoQuizPlan.ts` | ~281 | `POST /video-quiz-plan`. Sonnet returns the plan as schema-checked JSON and decides how many moments to pick. `parseVideoQuizPlan` moves a pause between two transcript lines to the next line start, moves a source time to the line playing then, lowercases function words, and checks the rest (tested in `worker/src/videoQuizPlan.test.ts`). Up to 2 retries name the broken rule, and each rejection logs "[/video-quiz-plan] attempt N rejected". |
| `worker/src/liveScene.ts` | ~350 | `POST /live-scene` asks GPT-6.1 Sol Ultrafast for a page and a quiz, checks the reply, and retries once. `POST /judge-answer` asks Sonnet for a verdict and one spoken sentence as schema-checked JSON. |
| `worker/src/videoFrameParts.ts` | ~185 | `POST /video-frame-parts`. Sonnet returns the subject box and part points as schema-checked JSON, and `checkFrameParts` clamps them into the frame and drops labels that are not short plain names (tested in `worker/src/videoFrameParts.test.ts`). |
| `worker/src/landmark.ts` | ~105 | `POST /landmark`, with `checkLandmark` rejecting coordinates off the globe (tested in `landmark.test.ts`). |
| `worker/src/mapTiles.ts` | ~45 | `GET /v1/3dtiles/...`, which forwards Google 3D Tiles requests with the key (tested in `mapTiles.test.ts`). |
| `worker/src/liveSceneReply.ts` | ~71 | Zod and plain checks for a live scene model reply: required page markers, no external URL, and a quiz JSON block. Tested in `worker/src/liveSceneReply.test.ts`. |
| `worker/src/anthropic.ts` | ~130 | Shared Worker helpers: JSON responses, request body parsing, the token usage log, `zodIssuesOnOneLine` for schema errors that must stay on one log line, and one Anthropic Messages call that returns the first text block parsed as JSON. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Cmd+U runs leanring-buddyTests (Swift Testing) hosted in Clicky.app. CI runs the same tests.

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
pnpm install

# Add secrets
pnpm wrangler secret put ANTHROPIC_API_KEY
pnpm wrangler secret put ELEVENLABS_API_KEY
pnpm wrangler secret put OPENAI_API_KEY
pnpm wrangler secret put GOOGLE_MAPS_API_KEY
# Only when Info.plist selects the assemblyai speech provider
pnpm wrangler secret put ASSEMBLYAI_API_KEY

# Deploy
pnpm wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
pnpm wrangler dev

# Test runs: build scenes with Sonnet (about $0.04 each) instead of GPT (about $0.23)
pnpm wrangler dev --var LIVE_SCENE_MODEL:sonnet

# Token use: every model call except the streamed /chat logs "[/route] usage {...}"
pnpm wrangler tail

# Tests and typecheck
pnpm test
pnpm run typecheck
```

pnpm 12 refuses to install a dependency with an unapproved build script.
`worker/pnpm-workspace.yaml` and `tools/three-tiles/pnpm-workspace.yaml` list each dependency build script under `allowBuilds`, approved with `true` (esbuild, workerd) or denied with `false` (sharp).

## CI

`.github/workflows/ci.yml` runs on every pull request and on pushes to main.
The `worker` job runs `pnpm test` and `pnpm run typecheck` in `worker/`.
The `app` job builds the `leanring-buddy` scheme on a GitHub macOS runner with Xcode 26.5 and `CODE_SIGNING_ALLOWED=NO`, then runs `leanring-buddyTests` hosted in the built `Clicky.app`.
Running xcodebuild there is fine, since the runner has no TCC permissions to lose.

## Verification

The `verify-clicky` project skill (`.claude/skills/verify-clicky/`) proves behavior on the real Worker and Debug app.
It drives Worker routes with curl and the app with the DEBUG-only `--live-scene-rehearsal` flag, and saves responses, usage lines, app logs, and screenshots under `.verify-clicky/runs/`.
Its feature map in `features/` lists each feature's recipe, and a change to a mapped feature updates its file.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
