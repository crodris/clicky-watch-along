# Clicky watch-along

This is my fork of [Clicky](https://github.com/farzaa/clicky), the open source version of [HeyClicky](https://www.heyclicky.com/). I built it on my Mac to help me remember what I learn from the YouTube videos I watch.

## What I added

**A watch-along quiz.** Open a YouTube video in Chrome, hold Control + Option, and say "watch this video with me and quiz me." Clicky reads the video's transcript, picks a few spots to quiz you on, and pauses and plays the video by itself. It only asks about parts you've already heard, and when you ask for help, it explains the answer before the video keeps going.

**3D models on request.** While the video is paused, ask Clicky to show you something in 3D. It sends a screenshot and what the video just said to GPT-6.1 Sol, which writes a labeled three.js scene, usually in about 8 to 14 seconds. The scene opens in Clicky's overlay, Clicky highlights each part as it talks, and you can drag to rotate and pinch to zoom. Press Escape to close it, and the video picks back up. HeyClicky's real-time graphics demo inspired this part.

## Running it

I run this locally, with the Worker on `npx wrangler dev`, and Debug builds point at `http://127.0.0.1:8787`. Follow the setup below, then add these:

- `OPENAI_API_KEY` in `worker/.dev.vars`, for the 3D scenes
- `brew install yt-dlp`, for the video transcripts
- In Chrome, turn on View, Developer, Allow JavaScript from Apple Events, so Clicky can pause and play the video

Speech uses Apple's speech recognition in this fork, so you don't need an AssemblyAI key. Release builds won't compile until you set your own https Worker URL in `CompanionManager.swift`. The Worker has no authentication or rate limits yet, so I wouldn't deploy it publicly as is.

Everything below is the original Clicky README.

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

Clone https://github.com/farzaa/clicky.git into my current directory.

Then read the CLAUDE.md. I want to get Clicky running locally on my Mac.

Help me set up everything — the Cloudflare Worker with my own API keys, the proxy URLs, and getting it building in Xcode. Walk me through it.
```

That's it. It'll clone the repo, read the docs, and walk you through the whole setup. Once you're running you can just keep talking to it — build features, fix bugs, whatever. Go crazy.

## Manual setup

If you want to do it yourself, here's the deal.

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Node.js 18+ (for the Cloudflare Worker)
- A [Cloudflare](https://cloudflare.com) account (free tier works)
- API keys for: [Anthropic](https://console.anthropic.com), [AssemblyAI](https://www.assemblyai.com), [ElevenLabs](https://elevenlabs.io)

### 1. Set up the Cloudflare Worker

The Worker is a tiny proxy that holds your API keys. The app talks to the Worker, the Worker talks to the APIs. This way your keys never ship in the app binary.

```bash
cd worker
npm install
```

Now add your secrets. Wrangler will prompt you to paste each one:

```bash
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY
```

For the ElevenLabs voice ID, open `wrangler.toml` and set it there (it's not sensitive):

```toml
[vars]
ELEVENLABS_VOICE_ID = "your-voice-id-here"
```

Deploy it:

```bash
npx wrangler deploy
```

It'll give you a URL like `https://your-worker-name.your-subdomain.workers.dev`. Copy that.

### 2. Run the Worker locally (for development)

If you want to test changes to the Worker without deploying:

```bash
cd worker
npx wrangler dev
```

This starts a local server (usually `http://localhost:8787`) that behaves exactly like the deployed Worker. You'll need to create a `.dev.vars` file in the `worker/` directory with your keys:

```
ANTHROPIC_API_KEY=sk-ant-...
ASSEMBLYAI_API_KEY=...
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...
```

Then update the proxy URLs in the Swift code to point to `http://localhost:8787` instead of the deployed Worker URL while developing. Grep for `clicky-proxy` to find them all.

### 3. Update the proxy URLs in the app

The app has the Worker URL hardcoded in a few places. Search for `your-worker-name.your-subdomain.workers.dev` and replace it with your Worker URL:

```bash
grep -r "clicky-proxy" leanring-buddy/
```

You'll find it in:
- `CompanionManager.swift` — Claude chat + ElevenLabs TTS
- `AssemblyAIStreamingTranscriptionProvider.swift` — AssemblyAI token endpoint

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

**Menu bar app** (no dock icon) with two `NSPanel` windows — one for the control panel dropdown, one for the full-screen transparent cursor overlay. Push-to-talk streams audio over a websocket to AssemblyAI, sends the transcript + screenshot to Claude via streaming SSE, and plays the response through ElevenLabs TTS. Claude can embed `[POINT:x,y:label:screenN]` tags in its responses to make the cursor fly to specific UI elements across multiple monitors. All APIs are proxied through a Cloudflare Worker.

## Project structure

```
leanring-buddy/          # Swift source (yes, the typo stays)
  CompanionManager.swift    # Central state machine
  CompanionPanelView.swift  # Menu bar panel UI
  ClaudeAPI.swift           # Claude streaming client
  ElevenLabsTTSClient.swift # Text-to-speech playback
  OverlayWindow.swift       # Blue cursor overlay
  AssemblyAI*.swift         # Real-time transcription
  BuddyDictation*.swift     # Push-to-talk pipeline
  VideoQuizSession.swift    # Watch-along quiz that pauses YouTube in Chrome
  LiveSceneOverlay.swift    # Transparent window that plays the 3D scene
worker/                  # Cloudflare Worker proxy
  src/index.ts              # Routes: /chat, /tts, /transcribe-token, /live-scene, /judge-answer, /video-quiz-plan
  src/videoQuizPlan.ts      # Picks the quiz spots from the transcript
  src/liveScene.ts          # Asks GPT-6.1 Sol for the 3D scene and grades spoken answers
CLAUDE.md                # Full architecture doc (agents read this)
```

## Contributing

PRs welcome. If you're using Claude Code, it already knows the codebase — just tell it what you want to build and point it at `CLAUDE.md`.

Got feedback? DM me on X [@farzatv](https://x.com/farzatv).
