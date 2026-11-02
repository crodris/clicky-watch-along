# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it via AssemblyAI streaming, and sends the transcript + a screenshot of the user's screen to Claude. Claude responds with text (streamed via SSE) and voice (ElevenLabs TTS). A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 4.6 default, Opus 4.6 optional) via Cloudflare Worker proxy with SSE streaming
- **Speech-to-Text**: AssemblyAI real-time streaming (`u3-rt-pro` model) via websocket, with OpenAI and Apple Speech as fallbacks
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
| `POST /scene` | `api.anthropic.com/v1/messages` | Picks a hand-tuned template (blue whale or water molecule), or generates a scene spec from the screenshot |
| `POST /watch-moment` | `api.anthropic.com/v1/messages` | Haiku reads the last 3 minutes of video speech and decides whether to pause for a quiz question. Returns `{ shouldPause: false }` or the question, answer label, function words, explanation, and 3D subject |
| `POST /live-scene` | `api.openai.com/v1/responses` | GPT-6.1 Sol Ultrafast writes a three.js page and a quiz from the question and screenshot |
| `POST /judge-answer` | `api.anthropic.com/v1/messages` | Haiku grades a spoken answer as correct, named only, or wrong |

Worker secrets: `ANTHROPIC_API_KEY`, `ASSEMBLYAI_API_KEY`, `ELEVENLABS_API_KEY`, `OPENAI_API_KEY`
Worker vars: `ELEVENLABS_VOICE_ID`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

**Field Trip Scene**: A transcript that contains "inside", "look like", or "show me" calls `POST /live-scene` while the normal voice answer plays, and every label stays visible. `POST /live-scene` asks GPT-6.1 Sol Ultrafast (`gpt-6.1-sol`, service tier `ultrafast`) for a self-contained three.js page and a quiz. The page imports three.js only from `clicky-asset://three/three.module.js`, which the overlay serves from the app bundle, and a content rule list blocks every http and https request. On a timeout, error, or 422, the app falls back to `POST /scene`. A transcript that says "quiz" or "test me" plays the same scene with one label shown as "?". Haiku picks a template on that fallback path. `blue_whale` (`scene/fixtures/whale.json`) and `water_molecule` (`scene/fixtures/water.json`) are hand-tuned templates and stay the fallback. The water drop uses `tissue.pattern: "liquid"`, which paints water with per-pixel alpha because the transparent overlay cannot refract the page behind it. Other subjects on the fallback path are generated by Sonnet and checked with `sceneSpecSchema`. The overlay plays the page on the screen under the mouse cursor. In a quiz, Clicky asks what that part is and what it does when the camera tour ends, and a correct name that misses what it does gets one follow-up. The learner answers by voice. `POST /judge-answer` asks Haiku to grade that answer as correct, named only, or wrong, and returns one spoken sentence. If the judge call fails, the app falls back to the word match in `FieldTripAnswerJudge`. A quiz with no explanation keeps the fixed spoken lines. A finished scene stays above every window until the next push-to-talk press clears it. During a quiz that press is an answer, so the quiz has to finish first. When the tour ends the overlay catches the mouse, and a drag orbits the camera around the last stop, within limits, and a trackpad pinch zooms it between set limits. The overlay never becomes key, so the pinch comes from the push-to-talk event tap, not AppKit. Gestures draw at pixel ratio 1 and one sharp frame follows about 150 ms after the input stops. The overlay is a nonactivating panel, so the page under it keeps the keyboard. `cd scene && node scripts/check-drag.mjs` checks the drag, the zoom, and the gesture frame time on the built page. `cd scene && node scripts/capture-whale.mjs [fixture]` saves one shot per camera stop to `scene/shots/<fixture>-*.png`, and the fixture defaults to `whale`. `--field-trip-spec <path>` reads a JSON spec, plays it through the same overlay, and returns before the menu bar app starts. The `scene/` package validates specs with Zod and renders them with three.js into `leanring-buddy/FieldTripScene.html`. Rebuild the HTML with `cd scene && pnpm install && node build.mjs`.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~119 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window. The app lives entirely in the status bar. `--field-trip-spec` plays a scene and returns early. |
| `FieldTripOverlay.swift` | ~432 | Reusable transparent window and page on the screen under the mouse. Plays a template spec or a live HTML page, serves bundled three.js at `clicky-asset`, blocks http and https, reveals the quiz label, and clears the scene. |
| `FieldTripSession.swift` | ~109 | Field-trip phase, scene kind, quiz, spoken-answer judge, and the transcript trigger that picks explore or quiz. |
| `VideoWatchAlongSession.swift` | ~420 | Listens to system audio with ScreenCaptureKit, keeps a rolling on-device transcript, asks `/watch-moment` when to pause, and presses YouTube's k key. |
| `WatchMomentClient.swift` | ~100 | Posts the transcript and screenshot to `POST /watch-moment`. |
| `FieldTripSceneClient.swift` | ~190 | Posts the cursor screen JPEG to `POST /scene` and `POST /live-scene`, and posts a spoken answer to `POST /judge-answer`. |
| `scene/src/spec.ts` | ~159 | Zod schema for a field-trip scene: parts, exactly three camera stops, and a quiz part id. |
| `scene/src/liveSceneReply.ts` | ~70 | Zod and plain checks for a live scene model reply: required page markers, no external URL, and a quiz JSON block. |
| `scene/src/main.ts` | ~812 | three.js renderer. Translucent shells, a three-stop camera tour, DOM labels, an optional "?" quiz label, and a tour-finished message. |
| `scene/fixtures/whale.json` | ~98 | Hand-written blue whale. Translucent shell, inner organs, last camera stop beside the heart. |
| `scene/fixtures/water.json` | ~328 | Hand-tuned water drop. Liquid teardrop shell, labeled H2O molecule at 104.5 degrees, last camera stop inside the drop. |
| `CompanionManager.swift` | ~1461 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the push-to-talk pipeline, the live field-trip page, the template fallback, and the spoken-answer judge. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~761 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Sonnet/Opus), permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
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
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `worker/src/index.ts` | ~160 | Cloudflare Worker proxy. Routes: `/chat` (Claude), `/tts` (ElevenLabs), `/transcribe-token` (AssemblyAI temp token), `/scene` (field-trip spec), `/live-scene` (generated page), `/judge-answer` (spoken grade). |
| `worker/src/scene.ts` | ~561 | `POST /scene`. Haiku picks `blue_whale`, `water_molecule`, or `none`. A template is returned as-is. Other subjects are generated live and validated. |
| `worker/src/liveScene.ts` | ~347 | `POST /live-scene` asks GPT-6.1 Sol Ultrafast for a page and a quiz, checks the reply, and retries once. `POST /judge-answer` asks Haiku for a verdict and one spoken sentence. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

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
