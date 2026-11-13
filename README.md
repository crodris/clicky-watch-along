# Clicky watch-along

This is my fork of [Clicky](https://github.com/farzaa/clicky), the open source version of [HeyClicky](https://www.heyclicky.com/). I built it on my Mac to help me remember what I learn from the YouTube videos I watch.

## What I added

**A watch-along quiz.** Open a YouTube video in Chrome, hold Control + Option, and say "watch this video with me and quiz me."
Clicky reads the video's transcript, and Sonnet picks the spots worth a question, spread across the video.
While it plans, a label next to your cursor says "Reading the transcript" and then "Picking spots to quiz you on."
Clicky pauses and plays the video by itself, and it only asks about parts you've already heard.
You answer out loud, and when you ask for help, it explains the answer before the video keeps going.
Press Escape to skip a question, or say "stop the quiz" to end it.

**The paused frame pops out in 3D.** Six seconds before each pause, Clicky grabs the video frame and asks Sonnet to find the subject and its parts.
When it finds one, the subject lifts out of the video in 3D with its parts labeled, and Clicky asks the question once the tour ends.
Charts and people talking stay voice only.
You can also say "pop this out" or "pop this heart out" at any time, and Clicky lifts out whatever the video shows, with every label and no question.
When that tour ends, Clicky talks about two or three of the parts, highlighting each one as it names it.
Click any label after that, and Clicky turns the model to that part and tells you what it does.
Each time Clicky names a part, its blue triangle flies onto the model, points at that label, and flies back to your mouse when Clicky is done talking.

**Pop out any image.** Say "pop this out" with any other page open in Chrome, and Clicky lifts the largest image on it out in 3D with its parts labeled.
You can drag to spin it.
It works best on 2D illustrations, like engravings and prints.
A painted scene, like The Starry Night, lifts out whole, sky included, while a drawing of one animal, like Dürer's Young Hare, lifts out only the animal.

**3D models on request.** Say "show me" or "in 3D" over a video, and Clicky pauses it.
It sends a screenshot and what the video just said to GPT-6.1 Sol, which writes a labeled three.js scene, usually in about 8 to 14 seconds.
Clicky says "Building your 3D scene" while it waits, and the scene grows out of the video once it's ready.
It shows the outside first, and opens it up when you ask to see inside.
Clicky highlights each part as it talks, and you can drag to rotate and pinch to zoom.
Add "quiz me" to the request, and one label shows as "?" for you to name.
Press Escape to close it, and the video picks back up.
HeyClicky's real-time graphics demo inspired this part.

**A loading label for each step.** Every step Clicky waits on has its own animated label next to your cursor, with its own colors and icon.
That covers popping out an image, reading your screen, building a 3D scene, reading a video's transcript, and picking quiz spots.
While a label shows, its icon sits where Clicky's blue triangle usually is, and the triangle comes back when the step is done.

**Famous places from Google's 3D scan.** Say "show me" over a frame of a famous place, like the Eiffel Tower, and Clicky shows Google's photorealistic 3D scan of it instead of building a model.
The scan is cut down to the structure and about 130 meters around it, and it floats over the video.
When the camera stops, Clicky names the place and says how tall it is.

## Running it

I run this locally, with the Worker on `pnpm wrangler dev`, and Debug builds point at `http://127.0.0.1:8787`.
Follow the setup below, which includes the OpenAI and Google Maps keys this fork needs, then add these:

- `brew install yt-dlp`, for the video transcripts
- In Chrome, turn on View, Developer, Allow JavaScript from Apple Events, so Clicky can pause and play the video

To test for less money, run `pnpm wrangler dev --var LIVE_SCENE_MODEL:sonnet`.
Sonnet then builds the 3D models for about $0.04 each, instead of about $0.23 with GPT.

Speech uses Apple's speech recognition in this fork, so you don't need an AssemblyAI key.
Release builds won't compile until you set your own https Worker URL in `CompanionManager.swift`.
The Worker has no authentication or rate limits yet, and its 3D Tiles route spends your Maps key for anyone who calls it, so I wouldn't deploy it publicly as is.

Everything below is the original Clicky README, with the setup, architecture, and project structure updated for this fork.

---

## Get HeyClicky for Mac and Windows

The official app is **[HeyClicky](https://www.heyclicky.com/)**, an AI buddy for Mac and Windows, made by me and the team.

- **Mac:** [download HeyClicky for Mac](https://www.heyclicky.com/for-mac) (macOS 14.2 or later)
- **Windows:** [download HeyClicky for Windows](https://www.heyclicky.com/for-windows) (Windows 10 and 11)

Those are the only official downloads. Other Windows apps built from this repo are community ports, not made by us.

---

Update: April 27, 2026.

Hi there! I'm Farza, the guy that made Clicky.

The existing codebase remains open source. Tinker with it, make it yours, start a company out of it, do whatever you want I don't mind. But, for all the new stuff I'm hacking on, gonna keep it private. To get the latest version, HeyClicky for Mac or Windows, go to [heyclicky.com](https://www.heyclicky.com/).

I also tweeted about this [here](https://x.com/FarzaTV/status/2043402737828962489).

Go crazy with this repo!! It's an MIT license.

# Hi, this is Clicky.
It's an AI teacher that lives as a buddy next to your cursor. It can see your screen, talk to you, and even point at stuff. Kinda like having a real teacher next to you.

Download HeyClicky for free for [Mac](https://www.heyclicky.com/for-mac) or [Windows](https://www.heyclicky.com/for-windows).

Here's the [original tweet](https://x.com/FarzaTV/status/2041314633978659092) that kinda blew up for a demo for more context.

![Clicky — an ai buddy that lives on your mac](clicky-demo.gif)

This is the open-source version of Clicky for those that want to hack on it, build their own features, or just see how it works under the hood.

## Get started with Claude Code

The fastest way to get this running is with [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Once you get Claude running, paste this:

```
Hi Claude.

Clone https://github.com/crodris/clicky-watch-along.git into my current directory.

Then read the CLAUDE.md. I want to get Clicky running locally on my Mac.

Help me set up everything — the Cloudflare Worker with my own API keys, the proxy URLs, and getting it building in Xcode. Walk me through it.
```

That's it. It'll clone the repo, read the docs, and walk you through the whole setup. Once you're running you can just keep talking to it — build features, fix bugs, whatever. Go crazy.

## Manual setup

If you want to do it yourself, here's the deal.

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 26 (CI builds with Xcode 26.5)
- Node.js 18+ and pnpm 12 (for the Cloudflare Worker)
- A [Cloudflare](https://cloudflare.com) account (free tier works)
- API keys for: [Anthropic](https://console.anthropic.com), [ElevenLabs](https://elevenlabs.io), [OpenAI](https://platform.openai.com) for the 3D models, and [Google Maps Platform](https://console.cloud.google.com/google/maps-apis) for the famous places, with the Map Tiles API turned on and billing linked
- Speech uses Apple's speech recognition, so you need an [AssemblyAI](https://www.assemblyai.com) key only if you switch back to it

### 1. Set up the Cloudflare Worker

The Worker is a tiny proxy that holds your API keys. The app talks to the Worker, the Worker talks to the APIs. This way your keys never ship in the app binary.

```bash
cd worker
pnpm install
```

Now add your secrets. Wrangler will prompt you to paste each one:

```bash
pnpm wrangler secret put ANTHROPIC_API_KEY
pnpm wrangler secret put ELEVENLABS_API_KEY
pnpm wrangler secret put OPENAI_API_KEY
pnpm wrangler secret put GOOGLE_MAPS_API_KEY
```

For the ElevenLabs voice ID, open `wrangler.toml` and set it there (it's not sensitive):

```toml
[vars]
ELEVENLABS_VOICE_ID = "your-voice-id-here"
```

Deploy it:

```bash
pnpm wrangler deploy
```

It'll give you a URL like `https://your-worker-name.your-subdomain.workers.dev`. Copy that.

### 2. Run the Worker locally (for development)

If you want to test changes to the Worker without deploying:

```bash
cd worker
pnpm wrangler dev
```

This starts a local server (usually `http://localhost:8787`) that behaves exactly like the deployed Worker. You'll need to create a `.dev.vars` file in the `worker/` directory with your keys:

```
ANTHROPIC_API_KEY=sk-ant-...
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...
OPENAI_API_KEY=...
GOOGLE_MAPS_API_KEY=...
```

Debug builds already call `http://127.0.0.1:8787`, so a local run needs no URL changes.

### 3. Point Release builds at your Worker

Debug builds call the local Worker, and Release builds won't compile until you set `workerBaseURL` in `CompanionManager.swift` to your deployed https Worker URL.
The placeholder URL in `AssemblyAIStreamingTranscriptionProvider.swift` matters only if you switch speech back to AssemblyAI.

### 4. Open in Xcode and run

```bash
open leanring-buddy.xcodeproj
```

In Xcode:
1. Select the `leanring-buddy` scheme (yes, the typo is intentional, long story)
2. Set your signing team under Signing & Capabilities
3. Hit **Cmd + R** to build and run

The app will appear in your menu bar (not the dock). Click the icon to open the panel, grant the permissions it asks for, and you're good.

### Permissions the app needs

- **Microphone** — for push-to-talk voice capture
- **Accessibility** — for the global keyboard shortcut (Control + Option)
- **Screen Recording** — for taking screenshots when you use the hotkey
- **Screen Content** — for ScreenCaptureKit access

## Architecture

If you want the full technical breakdown, read `CLAUDE.md`. But here's the short version:

**Menu bar app** (no dock icon) with two `NSPanel` windows — one for the control panel dropdown, one for the full-screen transparent cursor overlay. Push-to-talk transcribes your speech with Apple's speech recognition in this fork (upstream Clicky streams it to AssemblyAI), sends the transcript + screenshot to Claude via streaming SSE, and plays the response through ElevenLabs TTS. Claude can embed `[POINT:x,y:label:screenN]` tags in its responses to make the cursor fly to specific UI elements across multiple monitors. All APIs are proxied through a Cloudflare Worker.

## Project structure

```
leanring-buddy/          # Swift source (yes, the typo stays)
  CompanionManager.swift    # Central state machine
  CompanionPanelView.swift  # Menu bar panel UI
  ClaudeAPI.swift           # Claude streaming client
  ElevenLabsTTSClient.swift # Text-to-speech playback
  OverlayWindow.swift       # Blue cursor overlay
  AppleSpeech*.swift        # Speech recognition this fork uses
  AssemblyAI*.swift         # Upstream's real-time transcription, unused here
  BuddyDictation*.swift     # Push-to-talk pipeline
  VideoQuizSession.swift    # Watch-along quiz that pauses YouTube in Chrome
  LiveSceneOverlay.swift    # Transparent window that plays the 3D scene
  VideoFramePopout.swift    # Lifts the subject of a video frame or page image out in 3D
  ChromeWebArea.swift       # Finds where Chrome's page sits on screen, for the image pop-out
  LiveSceneStatusLine.swift # The loading label for each step and its animation
  LiveSceneStatusLabelViews.swift # Draws each loading label and its icon
  LandmarkTiles.swift       # Google's 3D scan of a famous place
worker/                  # Cloudflare Worker proxy
  src/index.ts              # Routes: /chat, /tts, /transcribe-token, /live-scene, /judge-answer, /video-quiz-plan, /video-frame-parts, /landmark, /v1/3dtiles
  src/videoQuizPlan.ts      # Picks the quiz spots from the transcript
  src/liveScene.ts          # Asks GPT-6.1 Sol for the 3D scene and grades spoken answers
  src/videoFrameParts.ts    # Finds the subject and its parts in a video frame or page image
  src/landmark.ts           # Recognizes a famous place in a video frame
  src/mapTiles.ts           # Forwards Google 3D Tiles requests with the Maps key
CLAUDE.md                # Full architecture doc (agents read this)
```

## Contributing

PRs welcome. If you're using Claude Code, it already knows the codebase — just tell it what you want to build and point it at `CLAUDE.md`.

Got feedback? DM me on X [@farzatv](https://x.com/farzatv).
