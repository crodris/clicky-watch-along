# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it with Apple Speech (this fork's provider; AssemblyAI streaming and OpenAI are the alternatives), and sends the transcript + a screenshot of the user's screen to Claude. Claude responds with text (streamed via SSE) and voice (ElevenLabs TTS, played as it streams in). A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 5.5 default, Opus 5.5 optional, both at low effort) via Cloudflare Worker proxy with SSE streaming. `ClaudeVoiceModel` in `ClaudeAPI.swift` holds the model IDs, and a choice saved by an older version moves to the latest model of its family. Use only the latest model of each family.
- **Prompt caching**: the app marks a cache breakpoint on the `/chat` system prompt (`ClaudeAPI.streamingRequestBody`), and the Worker puts one on the system prompt of every route that calls Anthropic, so later calls within 5 minutes read it at a tenth of the input price
- **Speech-to-Text**: Apple Speech, selected by `VoiceTranscriptionProvider` = `apple` in Info.plist. Setting it to `assemblyai` (real-time streaming over a websocket, `u3-rt-pro` model) or `openai` (upload on release) switches providers
- **Text-to-Speech**: ElevenLabs `eleven_v4_turbo` via Cloudflare Worker proxy, streamed as 24 kHz PCM and played as it arrives, so speech starts about 0.25 seconds after the request instead of after the whole line is generated
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
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}/stream` | ElevenLabs TTS audio, streamed. An `output_format` query such as `pcm_24000` passes through, and without one the audio is MP3 |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetches a short-lived (480s) AssemblyAI websocket token |
| `POST /live-scene` | `api.openai.com/v1/responses` | GPT-6.1 Sol Ultrafast writes a three.js page and a quiz from the question and screenshot |
| `POST /judge-answer` | `api.anthropic.com/v1/messages` | Sonnet grades a spoken answer as correct, named only, wrong, or a request for help |
| `POST /video-quiz-plan` | `api.anthropic.com/v1/messages` | Sonnet reads a video's timestamped transcript once, decides how many moments are worth a question, and picks them. Returns `{ moments: [{ pauseAtSeconds, sourceLineSeconds, question, answerLabel, functionWords, explanation, subject }] }`. Each moment lands on a transcript line boundary, at least 20 seconds in, and the moments are spread across the video |
| `POST /video-frame-parts` | `api.anthropic.com/v1/messages` | Sonnet finds the subject in a frame grabbed from the playing video, or a screen capture of a page image, and places up to 8 part labels, dropping any label that is not a short plain name. Returns `{ subjectFound, subjectBox, wholePictureIsSubject, parts: [{ label, x, y, isQuizAnswer }] }` in frame pixels, or `{ subjectFound: false }` for a chart or a person talking. `wholePictureIsSubject` is true for a painted scene, such as a landscape or a fresco of several figures, and its box covers the whole painting |
| `POST /landmark` | `api.anthropic.com/v1/messages` | Sonnet says whether a paused frame shows one famous real place, and returns `{ isFamousPlace, name, latitude, longitude, heightMeters, radiusMeters }` |
| `GET /v1/3dtiles/...` | `tile.googleapis.com` | Google Photorealistic 3D Tiles for the landmark page. Only `root.json` and dataset files pass, and the Worker adds `GOOGLE_MAPS_API_KEY` |

Worker secrets: `ANTHROPIC_API_KEY`, `ELEVENLABS_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_MAPS_API_KEY` (a Maps Platform key with the Map Tiles API enabled and billing linked), and `ASSEMBLYAI_API_KEY` only when Info.plist selects the `assemblyai` provider
Worker vars: `ELEVENLABS_VOICE_ID`, and optional `LIVE_SCENE_MODEL` (`gpt` by default, or `sonnet`)

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Interrupting a reply**: Escape or a quick ctrl+option tap stops the answer Clicky is thinking about or speaking, and a tap with no words asks nothing. With a scene or pop-out on screen, Escape keeps its scene behavior.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

**Live Scene**: A transcript that contains "inside", "look like", "show me", "3D", or "render" calls `POST /live-scene`, and every label stays visible.
`POST /live-scene` asks GPT-6.1 Sol Ultrafast (`gpt-6.1-sol`, service tier `ultrafast`) for a self-contained three.js page and a quiz.
The page builds the whole subject from the outside, and adds the parts inside, fading the outer shell, only when the learner asks to see inside.
The page imports three.js only from `clicky-asset://three/three.module.js`, which the overlay serves from the app bundle.
The overlay serves the generated page from `clicky-asset://live/page.html` with a Content-Security-Policy header, a content rule blocks http, https, ws, and wss, and navigation is limited to `about` and `clicky-asset`.
On a timeout, an error, or a 422, Clicky says "Sorry, I couldn't build that one." and resumes a video it paused for the scene.
A page that fails to load, or whose web content process ends, takes the same recovery as a page that throws: a quiz falls back to the voice-only question, and a scene says that line.
Only a failure of the load Clicky started counts (`pageLoadFailureEndsTheScene`), where that load is the `WKNavigation` that `load(_:)` returned, so a navigation the page starts itself, or one the policy refuses with WebKit error 102, leaves the scene on screen.
A transcript that says "quiz" or "test me" plays the same scene with one label shown as "?".
The overlay plays a generated scene on the screen under the mouse cursor.
A frame pop-out or landmark page plays on the screen showing its video or image instead, so it lines up even when the mouse is on another display.
The page rises out of the video or image it was asked about: Clicky reads the on-screen rect of the largest visible video or image in Chrome's front tab before the request, skipping images that show nothing (not loaded, hidden, or fully transparent), and places the rect from the web area in Chrome's accessibility tree, with the page-geometry math as the fallback when no web area matches, and `LiveSceneRise.swift` adds the cursor screenshot and that rect to the page for the bundled `scene-rise.js`, which shows the screenshot clipped to the rect and grows the page out of it once the scene is ready.
In a quiz, Clicky asks what that part is and what it does when the camera tour ends, and a correct name that misses what it does gets one follow-up.
The learner answers by voice.
`POST /judge-answer` asks Sonnet to grade that answer as correct, named only, wrong, or a request for help, and returns one spoken sentence.
If the judge call fails, the app falls back to the word match in `LiveSceneAnswerJudge`.
A finished scene stays above every window until Escape clears it.
A frame pop-out does not vanish when it clears.
`window.liveScene.returnToSource()` in `frame-popout.html` fades the labels, eases the camera back to its starting pose, and flattens the subject back into the frame exactly over the video rect in 0.8 seconds, then posts `returnFinished` through `liveSceneEvent`.
`LiveSceneOverlay` tracks this as `LiveSceneOverlayPhase` (`hidden`, `showing(isFramePopout:)`, `returningToSource`).
`clear()` on a frame pop-out starts the return, and the window hides on `returnFinished` or after a 1.5 second fallback.
A second `clear()` during the return, a new scene, or any non-pop-out page hides at once, and `clear()` on a hidden overlay does nothing.
`waitForReturnToFinish()` returns when the window has hidden, and every path that resumes a video Clicky paused awaits it first, so the subject lands in the still frame before the video moves.
That includes "stop the quiz", which clears the question's pop-out before `VideoQuizSession.stop()` and then plays the video with `resumeVideoAfterQuestion()`, a plain question or "stop the quiz" that cancels a scene build, a pop-out that fails to open, and "Sorry, I couldn't build that one."
"Stop the quiz" reads whether a scene was building before it resets the phase for an open question, so a scene asked for on another tab is cancelled too.
Every clear in `CompanionManager` goes through `clearTheLiveSceneAndReleaseTheBuddy()`, which also sends the blue cursor back to the mouse when a narration holds it on a part, since a narration cancelled mid-sentence may never release it.
Only `frame-popout.html` has `returnToSource` and `answerMoment`, so generated pages and `landmark-tiles.html` keep the old instant clear and plain reveal.
During a video quiz question, Escape skips the question, clears its pop-out, and plays the video on.
When the tour ends the overlay catches the mouse, a drag orbits the camera around the last stop, and a trackpad pinch zooms it.
The overlay never becomes key, so the pinch comes from the push-to-talk event tap, not AppKit.
The overlay is a nonactivating panel, so the page under it keeps the keyboard.
Before any public release, add a runtime block for WebRTC in dynamically created frames, add authentication and rate limits to the Worker (the `GET /v1/3dtiles/` route spends the Maps key for any caller), send video captions to /live-scene as a separate untrusted field instead of merging them into the learner's request, and pass part labels read from a generated page as sanitized untrusted data instead of putting them in the system prompt.

**Video Quiz**: A voice request to watch a video and be quizzed starts `VideoQuizSession`: it reads the YouTube tab through AppleScript, gets timestamped captions with yt-dlp, asks `POST /video-quiz-plan` for the moments, and pauses at each one through JavaScript in Chrome. Saying only "watch this with me" starts nothing. Saying "stop the quiz" (or end, cancel, quit, or "done with the quiz") stops it, along with "stop quizzing", "stop watching", and "can we stop" or "let's stop" when speech recognition drops the last word. Push-to-talk keeps the microphone on for half a second after the shortcut is released, so the last word is not cut off, and Apple Speech gets Clicky's command phrases as contextual strings. While Clicky reads the captions and plans, the status label says "Reading the transcript" and then "Picking spots to quiz you on". A scene or pop-out asked for over a playing YouTube video in Chrome's front tab pauses it, with or without a quiz, and resumes it when the scene clears. During a quiz it pauses only the quiz video, when its tab is the one in front. `VideoQuizSession` keeps one record of a video Clicky paused (a quiz question or a requested scene, with its tab), and presses play only for that record, so a video the learner paused stays paused. Saying "stop the quiz" while a question is up clears its pop-out and plays the video again once the pop-out has landed. A question whose pause a requested scene took over is skipped instead of asked (`quizQuestionMayStillBeAsked`). A scene or pop-out asked for during a quiz question sets the question aside and clears its pop-out, so the new scene replaces it and Escape still works. Six seconds before each pause, while the video plays, it grabs the frame from the `<video>` element through JavaScript and asks `POST /video-frame-parts` for the subject and its labels. At the pause it uses that early grab when it found a subject, because the pop-out covers the video with its own frame. It grabs the paused frame only when the early grab found nothing or never ran. When a subject was found, `frame-popout.html` lifts it out of the frame in 3D, starting exactly over the video on screen, and Clicky asks the question when that tour ends. Otherwise the question is voice only. On a quiz pop-out the "?" label is larger and Clicky blue (`DS.Colors.overlayCursorBlue`, mirrored as `--clicky-blue` in `frame-popout.html`).
`applyJudgedLiveSceneAnswer` maps the verdict to a `LiveSceneRevealOutcome` in one place (`LiveSceneRevealOutcome(grade:wrongAnswerCount:)`) and calls `LiveSceneOverlay.revealQuizLabel(outcome:)`.
For a frame pop-out the page's `answerMoment` receives the outcome string.
`celebrateCorrectName` (a correct name, even name only) turns the label green (`DS.Colors.success`, mirrored as `--clicky-success-green`) with the real name and a one-shot ring burst at the part's anchor, and Swift plays the "Glass" system sound once.
`shakeAndKeepTheQuestionMark` (a first wrong answer) shakes the label once and keeps the "?".
`revealWithoutCelebration` (asked for help, or a second wrong answer) shows the name in the normal color.
Reduce Motion skips the shake and the ring and keeps the color change.
For a generated page, `revealQuizLabel` still calls plain `reveal()`, and a first wrong answer reveals nothing.
The pop-out lands back in the frame, then clears before the video plays again. Saying "pop this out" (or "pop out", or up to 3 words between, as in "pop this heart out") lifts the subject of the frame the YouTube tab shows right now out in 3D with every label and no question, using the same frame grab, `POST /video-frame-parts`, and `frame-popout.html`; it pauses a playing video first, with or without a quiz. When that tour ends, Clicky speaks two or three short sentences about the parts, one part each, written for a curious 11-year-old, and highlights each part as it names it. The Claude call for those sentences starts when the pop-out starts, with the paused frame and the part labels from the `/video-frame-parts` reply, so the speech is ready when the camera stops. For an image on a web page, the prompt and the attached image say picture instead of video (`FramePopoutSource`, read from whether the grab has a video time). A quiz pop-out asks its question instead, and a quiz question that arrives during a narration stops it before the question's pop-out plays. After the tour of a pop-out with no quiz, its labels take clicks: a click that moves 4 px or less posts `partTapped:<label>` to the `liveSceneEvent` handler, and a longer press stays a drag that turns the model. Clicky accepts the tap only from the bundled frame pop-out, only in `.allLabelsShowing`, outside a video quiz question, and only for a label in the pop-out's own parts list (`partLabelToExplain`). It then turns the camera to that part and answers "what does the <label> do?" through the same narration. As the narration names each part, the blue cursor flies on its bezier arc to that part's label with the label in its bubble. `LiveSceneOverlay.partLabelScreenPointsOnceTheCameraSettles()` reads each `.scene-label` box with getBoundingClientRect once the camera glide ends, and `partScreenPoint(of:overlayScreenFrame:)` turns it into a global AppKit point under the label. That point is held (`BuddyPointingHold.untilReleased`) until the narration that set it ends, and then the cursor flies back to the mouse. `labelRectsOnceTheCameraSettles` waits on timers, not animation frames, which stop once the window hides, and returns no labels once the return has started. The cursor overlay windows sit one level above `.screenSaver`, above the live scene window and the status label, so the triangle draws over the scene; they ignore the mouse, so clicks still reach the scene. The overlay never becomes key, so `LiveSceneWebView` adds an always-active tracking area to give the page the mouse moves that drive its label hover. When Chrome's front tab is not a YouTube video, it lifts the largest visible video or image on the page instead. Clicky captures the screen under it at the display's pixel density, up to 1280 pixels on the longest side, showing only Chrome's windows, because a page canvas cannot read an image served from another site. Apple's subject lifting cuts the subject out of the frame. For a painted scene, such as The Starry Night, `POST /video-frame-parts` returns `wholePictureIsSubject: true`. The painting then lifts out whole, sky included, since subject lifting would keep only the cypress. Art of one animal or object on a plain background, such as Dürer's Young Hare, still lifts out only the animal. When "show me" or "render this in 3D" is said over a YouTube frame that `POST /landmark` recognizes as a famous place, `landmark-tiles.html` shows Google's real 3D scan of it instead, cut down to the structure and about 130 m of its surroundings and floating over the video. The overlay fetches the tiles from `clicky-asset://tiles/`, which the asset handler forwards to the Worker, so the page never holds the key or reaches the network, and only this bundled page gets the policy that allows its WebAssembly Draco decoder. A 3D model built from scratch appears only on request: "show me" or "in 3D" pauses the video and builds one from what the video just said, and clearing it resumes the video.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~98 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window. The app lives entirely in the status bar. |
| `LiveSceneOverlay.swift` | ~720 | Reusable transparent window and page on the screen it is given: the mouse screen for generated scenes, the screen showing the video or image for pop-outs and landmark pages. Serves the generated page and bundled three.js at `clicky-asset`, blocks network requests, resolves the quiz label, passes label taps from the page, reads where each part label sits on screen, and clears the scene, playing the return first for a frame pop-out (`LiveSceneOverlayPhase`). |
| `LiveSceneSession.swift` | ~205 | Live scene phase, scene kind, quiz, `LiveSceneRevealOutcome`, spoken-answer judge, the transcript trigger that picks explore, quiz, or frame pop-out, and the `[PART:label]` splitter for spoken replies. |
| `VideoQuizSession.swift` | ~1015 | Voice command, Chrome tab finder, yt-dlp caption reader, and the session that pauses a YouTube video at each planned moment, or for a requested scene, and remembers which pauses are Clicky's. Talks to Chrome through AppleScript, posts the transcript to `POST /video-quiz-plan`, and grabs each moment's frame while the video plays. |
| `LiveSceneStatusLabel.swift` | ~160 | Label next to the cursor while Clicky pops something out, builds a scene, or plans a video quiz. It takes a `LiveSceneStatusLine`, leaves the view tree when hidden so its loop stops, and runs the loop at 30 frames a second (paused with Reduce Motion). Each owner (pop-out, scene build, video quiz) hides only its own lines with `hide(onlyIfShowingOneOf:)`, and a delayed swap uses `replace(_:with:)` so a line never returns after a push-to-talk press hid the label. It publishes whether the screen's edge moved the panel off the triangle's spot. Clicky also says "Building your 3D scene" and "Almost there" out loud. |
| `LiveSceneStatusLine.swift` | ~330 | The six status lines, each with its own `DS.Colors` palette and looping letter animation, the sets of lines each owner may hide, and the pop-out cube's pose. The math takes a time and returns a pose, so tests check it without drawing. |
| `LiveSceneStatusLabelViews.swift` | ~470 | Draws a status line: an animated icon on a white tile (drawn in a `Canvas`), then letters with a white outline. |
| `VideoFramePopout.swift` | ~365 | The grabbed frame, the `POST /video-frame-parts` client, and the pop-out page built from the bundled `LiveSceneAssets/frame-popout.html` template with the video rect moved into the overlay screen's coordinates. Its `screenRectInChromeCoordinates(from:backingScaleFactor:)` is the fallback that places a page element from the window and page geometry when `ChromeWebArea.swift` finds no web area. |
| `ChromeWebArea.swift` | ~140 | Reads the screen frame of the page viewport from the web area in Chrome's accessibility tree (the Accessibility permission Clicky already has), and picks the web area that matches the page's shape to place the image rect, which holds with side panels, vertical tabs, or docked DevTools in the window. Turning on Chrome's accessibility tree keeps it on for the rest of Chrome's session, which costs Chrome some CPU and memory. |
| `LiveSceneRise.swift` | ~50 | Loads the bundled `LiveSceneAssets/scene-rise.js` and adds it, with the cursor screenshot and the media rect, before the last `</body>` of a generated page. |
| `LiveSceneAssets/scene-rise.js` | ~90 | Runs after a generated page's body. Shows the screenshot clipped to the media rect, shrinks the body onto that rect, then lifts it to full screen over 1.6 seconds once `window.__ready` is true or after 1.5 seconds. |
| `LandmarkTiles.swift` | ~105 | The `POST /landmark` client and the landmark page built from `LiveSceneAssets/landmark-tiles.html`. `three-tiles.js` and the Draco decoder in `LiveSceneAssets` are built by `tools/three-tiles` (`pnpm install && pnpm run build`). |
| `LiveSceneNarration.swift` | ~165 | What Clicky says about a bundled page: the record of which page is on screen (`LiveScenePageOnScreen`), the narration trigger (after the tour, or a tapped label), the page events parsed at the page boundary, the rule that accepts a label tap, the frame pop-out narration prompts for a YouTube frame or a page image (`FramePopoutSource`), the landmark line, and the conversion from a part label's page box to the global point the blue cursor flies to. |
| `LiveSceneClient.swift` | ~180 | Posts the cursor screen JPEG to `POST /live-scene`, and posts a spoken answer to `POST /judge-answer`. |
| `CompanionManager.swift` | ~2030 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the push-to-talk pipeline, the live scene, the video quiz, the spoken-answer judge, and the narration of bundled pages with the cursor pointing at each part. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~761 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Sonnet/Opus), permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~940 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Its windows sit one level above `.screenSaver`, so the cursor draws over a live scene. A target with a `BuddyPointingHold` of `untilReleased` stays pointed at until the location clears. Hides the triangle, spinner, and waveform while a status line shows, the buddy follows the cursor, and the icon sits on the triangle's spot. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~236 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display, and captures one page image's screen rect (Chrome's windows only, at the display's pixel density, up to 1280 pixels on the longest side) for the image pop-out. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeAPI.swift` | ~314 | Claude vision API client with streaming (SSE) and non-streaming modes. `ClaudeVoiceModel` holds the latest Sonnet and Opus IDs, and `streamingRequestBody` builds the voice reply's request at low effort with the system prompt cached. TLS warmup optimization, image MIME detection, conversation history support. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | ~256 | ElevenLabs TTS client. Asks the Worker for streamed 24 kHz PCM and plays it through an `AVAudioEngine` player node in fifth-of-a-second buffers as it arrives. `speakText` returns once audio is playing, and `isPlaying` stays true while audio plays or is still arriving. The engine pauses between lines, an output device change ends a line that is already playing, and a reply that is not PCM, such as MP3 from a Worker deployed before streaming, throws. `PCM16StreamChunker` turns the streamed bytes into samples. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~920 | Design system tokens — colors (including the status line palettes), corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `leanring-buddyTests/leanring_buddyTests.swift` | ~636 | Swift Testing unit tests for voice-command parsing, quiz grading, the reveal outcome and overlay clear transitions, narration label matching, page event parsing, the narration prompt for a page image, label-tap acceptance, the page load failures that end a scene, the cursor release on a scene clear, the part label's page-to-screen conversion, the live scene trigger and rise script, the image pop-out's rect and screen choice, the status label's animation and line ownership, the permission gate, the streamed speech chunker, the saved model choice mapping, and the voice reply's request body. They import `Clicky` and run on the main actor, hosted in `Clicky.app`. |
| `worker/src/index.ts` | ~185 | Cloudflare Worker proxy. Routes: `/chat` (Claude), `/tts` (ElevenLabs), `/transcribe-token` (AssemblyAI temp token), `/live-scene` (generated page), `/judge-answer` (spoken grade), `/video-quiz-plan` (video quiz moments), `/video-frame-parts` (subject and labels in a frame). The `/chat` pass-through and the `/tts` output format are tested in `worker/src/index.test.ts`. |
| `worker/src/videoQuizPlan.ts` | ~281 | `POST /video-quiz-plan`. Sonnet returns the plan as schema-checked JSON and decides how many moments to pick. `parseVideoQuizPlan` moves a pause between two transcript lines to the next line start, moves a source time to the line playing then, lowercases function words, and checks the rest (tested in `worker/src/videoQuizPlan.test.ts`). Up to 2 retries name the broken rule, and each rejection logs "[/video-quiz-plan] attempt N rejected". |
| `worker/src/liveScene.ts` | ~350 | `POST /live-scene` asks GPT-6.1 Sol Ultrafast for a page and a quiz, checks the reply, and retries once. `POST /judge-answer` asks Sonnet for a verdict and one spoken sentence as schema-checked JSON. |
| `worker/src/videoFrameParts.ts` | ~185 | `POST /video-frame-parts`. Sonnet returns the subject box and part points as schema-checked JSON, and `checkFrameParts` clamps them into the frame, drops labels that are not short plain names, and keeps a painted scene (`wholePictureIsSubject`) found even when the model marks it as no single object (tested in `worker/src/videoFrameParts.test.ts`). |
| `worker/src/landmark.ts` | ~105 | `POST /landmark`, with `checkLandmark` rejecting coordinates off the globe (tested in `landmark.test.ts`). |
| `worker/src/mapTiles.ts` | ~45 | `GET /v1/3dtiles/...`, which forwards Google 3D Tiles requests with the key (tested in `mapTiles.test.ts`). |
| `worker/src/liveSceneReply.ts` | ~71 | Zod and plain checks for a live scene model reply: required page markers, no external URL, and a quiz JSON block. Tested in `worker/src/liveSceneReply.test.ts`. |
| `worker/src/anthropic.ts` | ~160 | Shared Worker helpers: JSON responses, request body parsing, the token usage log (which names the model), `zodIssuesOnOneLine` for schema errors that must stay on one log line, `withCachedSystemPrompt`, and one Anthropic Messages call that returns the first text block parsed as JSON. |
| `bench/bench.ts` | ~803 | Benchmark of every Worker route the demo uses, on fixed fixtures in `bench/fixtures/`: latency, tokens, cost, and a quality check per call, with results in `bench/results/`. Each side of a comparison sends what its own app version sends. See `bench/README.md`. |
| `bench/report.ts` | ~185 | Turns benchmark result files into the CSV tables a chart page reads. CI runs it on every committed result. |

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
The `bench` job typechecks `bench/` and checks that the committed results in `bench/results/` still parse.
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
