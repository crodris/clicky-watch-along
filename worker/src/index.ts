/**
 * Clicky Proxy Worker
 *
 * Proxies requests to Claude, OpenAI, and ElevenLabs so the app never
 * ships with raw API keys. Keys are stored as Cloudflare secrets.
 *
 * Routes:
 *   POST /chat         → Anthropic Messages API (streaming)
 *   POST /tts          → ElevenLabs TTS API
 *   POST /live-scene   → OpenAI Responses API, or Anthropic with LIVE_SCENE_MODEL=sonnet (generated live-scene page)
 *   POST /judge-answer → Anthropic Messages API (spoken answer grade)
 *   POST /video-quiz-plan → Anthropic Messages API (quiz pause moments for a video transcript)
 *   POST /video-frame-parts → Anthropic Messages API (subject box and part labels in a video frame)
 *   POST /landmark     → Anthropic Messages API (famous place and coordinates in a video frame)
 *   POST /voice-command → Anthropic Messages API (Haiku picks the app's tools for a spoken follow-up command)
 *   GET  /v1/3dtiles/...  → Google Photorealistic 3D Tiles, with the key added
 */

import { handleJudgeAnswer, handleLiveScene } from "./liveScene";
import { handleVideoQuizPlan } from "./videoQuizPlan";
import { handleVideoFrameParts } from "./videoFrameParts";
import { handleMapTiles, isMapTilesRequest } from "./mapTiles";
import { handleLandmark } from "./landmark";
import { handleVoiceCommand } from "./voiceCommand";

interface Env {
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
  OPENAI_API_KEY: string;
  /** "gpt" (the default) or "sonnet". Test runs start the Worker with --var LIVE_SCENE_MODEL:sonnet. */
  LIVE_SCENE_MODEL?: string;
  /** Google Maps Platform key with the Map Tiles API enabled, for landmark renders. */
  GOOGLE_MAPS_API_KEY?: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && isMapTilesRequest(url)) {
      return await handleMapTiles(request, env.GOOGLE_MAPS_API_KEY);
    }

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }

      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }

      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }

      if (url.pathname === "/video-quiz-plan") {
        return await handleVideoQuizPlan(request, env.ANTHROPIC_API_KEY);
      }

      if (url.pathname === "/live-scene") {
        return await handleLiveScene(request, env);
      }

      if (url.pathname === "/video-frame-parts") {
        return await handleVideoFrameParts(request, env.ANTHROPIC_API_KEY);
      }

      if (url.pathname === "/landmark") {
        return await handleLandmark(request, env.ANTHROPIC_API_KEY);
      }

      if (url.pathname === "/voice-command") {
        return await handleVoiceCommand(request, env.ANTHROPIC_API_KEY);
      }

      if (url.pathname === "/judge-answer") {
        return await handleJudgeAnswer(request, env.ANTHROPIC_API_KEY);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleChat(request: Request, env: Env): Promise<Response> {
  const body = await request.text();

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] Anthropic API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI token error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const body = await request.text();
  const voiceId = env.ELEVENLABS_VOICE_ID;

  // The stream endpoint sends audio as it is generated, so the app can start speaking before the line is done.
  const elevenLabsURL = new URL(`https://api.elevenlabs.io/v1/text-to-speech/${voiceId}/stream`);
  const requestedOutputFormat = new URL(request.url).searchParams.get("output_format");
  if (requestedOutputFormat !== null && /^(mp3|pcm)_\d+(_\d+)?$/.test(requestedOutputFormat)) {
    elevenLabsURL.searchParams.set("output_format", requestedOutputFormat);
  }

  const response = await fetch(elevenLabsURL, {
    method: "POST",
    headers: {
      "xi-api-key": env.ELEVENLABS_API_KEY,
      "content-type": "application/json",
    },
    body,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] ElevenLabs API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}
