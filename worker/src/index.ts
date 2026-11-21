/**
 * Clicky Proxy Worker
 *
 * Proxies requests to Claude, OpenAI, and ElevenLabs so the app never
 * ships with raw API keys. Keys are stored as Cloudflare secrets.
 *
 * Routes:
 *   POST /chat         → Anthropic Messages API (streaming)
 *   POST /v1/messages  → Anthropic Messages API (the body and stream pass through unchanged, for the agent harness's SDK)
 *   POST /tts          → ElevenLabs TTS API
 *   POST /transcribe-token → AssemblyAI streaming token API (a short-lived websocket token, only when Info.plist selects the assemblyai provider)
 *   POST /live-scene   → OpenAI Responses API (GPT-6.1 Sol for a model, GPT-6.2 Sol for a simulation), or Anthropic with LIVE_SCENE_MODEL=sonnet, opus, or fable, or Anthropic Messages API when OpenAI cannot answer (generated live-scene page)
 *   POST /judge-answer → Anthropic Messages API (spoken answer grade)
 *   POST /video-quiz-plan → OpenAI Responses API (GPT-6.2 Sol), or Anthropic Messages API when OpenAI cannot answer (quiz pause moments for a video transcript)
 *   POST /video-frame-parts → Anthropic Messages API (subject box and part labels in a video frame)
 *   POST /landmark     → Anthropic Messages API (famous place and coordinates in a video frame)
 *   POST /voice-command → Anthropic Messages API (Haiku picks the app's tools for a spoken follow-up command)
 *   POST /picture-flows → Anthropic Messages API (paths of what flows through a popped-out picture)
 *   POST /theme-ideas  → Anthropic Messages API (Sonnet writes three cursor theme ideas for the theme studio, optionally from a picture)
 *   POST /study-guide  → Anthropic Messages API (Sonnet drafts a study guide), then Notion API (creates the page, trashes the one a revision replaces)
 *   POST /study-guide-status → Notion API (whether a saved guide's page is still out of the trash)
 *   POST /notion-page  → Notion API (a background agent's findings as a private page)
 *   GET  /v1/3dtiles/...  → Google Photorealistic 3D Tiles, with the key added
 *
 * A Worker started with --var BENCH_MODEL:<model> runs the model routes and /chat on that model, for bench/bench.ts
 * (see benchModelOverride.ts). The deployed Worker and the app's Worker never set it.
 */

import { appSecretHeaderName, requestCarriesTheAppSecret, routesThatNeedTheAppSecret } from "./appSecret";
import { jsonResponse } from "./anthropic";
import { benchModelOverride, claudeChatBodyText, configureBenchModelOverride, forwardChatToGemini, forwardChatToOpenAI } from "./benchModelOverride";
import { handleNotionPage } from "./notionPage";
import { handleJudgeAnswer, handleLiveScene } from "./liveScene";
import { handleVideoQuizPlan } from "./videoQuizPlan";
import { handleVideoFrameParts } from "./videoFrameParts";
import { handleMapTiles, isMapTilesRequest } from "./mapTiles";
import { handleLandmark } from "./landmark";
import { handleVoiceCommand } from "./voiceCommand";
import { handlePictureFlows } from "./pictureFlows";
import { handleThemeIdeas } from "./themeIdeas";
import { handleStudyGuide, handleStudyGuideStatus } from "./studyGuide";

interface Env {
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
  OPENAI_API_KEY: string;
  /** "gpt" (the default), "sonnet", "opus", or "fable". Test runs start the Worker with --var LIVE_SCENE_MODEL:sonnet. */
  LIVE_SCENE_MODEL?: string;
  /** Overrides the scene model's effort, which is medium for GPT and low for Claude. GPT takes low, medium, or high. */
  LIVE_SCENE_EFFORT?: string;
  /** Google Maps Platform key with the Map Tiles API enabled, for landmark renders. */
  GOOGLE_MAPS_API_KEY?: string;
  /**
   * A Notion personal access token, which acts as its owner across their whole workspace, so /study-guide can create
   * private pages with no parent. Without it, /study-guide, /study-guide-status, and /notion-page answer 503.
   */
  NOTION_API_KEY?: string;
  /** The secret the app sends in x-clicky-app-secret. The Notion routes and /v1/messages refuse a request without it. */
  CLICKY_APP_SECRET?: string;
  /** Local benchmark runs only: a gemini-* BENCH_MODEL calls Google's OpenAI-compatible endpoint with this key. */
  GEMINI_API_KEY?: string;
  /** Local benchmark runs only: a claude-*, gpt-*, or gemini-* model that replaces the one each model route and /chat asks for. */
  BENCH_MODEL?: string;
  /** With BENCH_MODEL: replaces the route's effort. */
  BENCH_EFFORT?: string;
  /** With a gpt-* BENCH_MODEL: the OpenAI service tier, such as ultrafast. */
  BENCH_SERVICE_TIER?: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    const benchOverrideProblem = configureBenchModelOverride(env);
    if (benchOverrideProblem !== undefined) {
      return jsonResponse({ error: benchOverrideProblem }, 500);
    }

    if (request.method === "GET" && isMapTilesRequest(url)) {
      return await handleMapTiles(request, env.GOOGLE_MAPS_API_KEY);
    }

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    // Checked before any handler runs, so a caller without the app's secret never reaches Notion or the task agent.
    if (routesThatNeedTheAppSecret.has(url.pathname) && !(await requestCarriesTheAppSecret(request, env.CLICKY_APP_SECRET))) {
      return new Response(JSON.stringify({ error: `Missing or wrong ${appSecretHeaderName}` }), {
        status: 401,
        headers: { "content-type": "application/json" },
      });
    }

    try {
      if (url.pathname === "/chat") {
        return await forwardToAnthropic(request, env, { routeName: "/chat", forwardsCallerBetaHeader: false });
      }

      if (url.pathname === "/v1/messages") {
        return await forwardToAnthropic(request, env, { routeName: "/v1/messages", forwardsCallerBetaHeader: true });
      }

      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }

      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }

      if (url.pathname === "/video-quiz-plan") {
        return await handleVideoQuizPlan(request, env.ANTHROPIC_API_KEY, env.OPENAI_API_KEY);
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

      if (url.pathname === "/picture-flows") {
        return await handlePictureFlows(request, env.ANTHROPIC_API_KEY);
      }

      if (url.pathname === "/theme-ideas") {
        return await handleThemeIdeas(request, env.ANTHROPIC_API_KEY);
      }

      if (url.pathname === "/study-guide") {
        return await handleStudyGuide(request, env);
      }

      if (url.pathname === "/study-guide-status") {
        return await handleStudyGuideStatus(request, env);
      }

      if (url.pathname === "/notion-page") {
        return await handleNotionPage(request, env.NOTION_API_KEY);
      }

      if (url.pathname === "/judge-answer") {
        return await handleJudgeAnswer(request, env.ANTHROPIC_API_KEY);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: "The Worker failed to handle the request" }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

/**
 * Sends the caller's request body to Anthropic's Messages API as it is and streams the reply back with its status and
 * content type. Both /chat and /v1/messages come here, so the Worker holds the API key and nothing else changes the
 * request.
 *
 * forwardsCallerBetaHeader is true only for /v1/messages, which requires the app secret. /chat has no secret gate, so
 * it never passes the caller's anthropic-beta header on, and an anonymous caller cannot switch on beta features.
 */
async function forwardToAnthropic(
  request: Request,
  env: Env,
  options: { routeName: string; forwardsCallerBetaHeader: boolean },
): Promise<Response> {
  let body = await request.text();

  // /chat and /v1/messages, the agent harness's task agent, run on the benchmark's model. The task agent uses
  // Anthropic's server-side web search and fetch, so only a Claude model can run it.
  const benchOverride = benchModelOverride();
  if (options.routeName === "/v1/messages" && benchOverride !== undefined && benchOverride.provider !== "anthropic") {
    return jsonResponse({ error: `The task agent runs only on Claude, not ${benchOverride.model}` }, 501);
  }
  if (benchOverride?.provider === "openai") {
    return await forwardChatToOpenAI(benchOverride, body);
  }
  if (benchOverride?.provider === "gemini") {
    return await forwardChatToGemini(benchOverride, body);
  }
  if (benchOverride?.provider === "anthropic") {
    body = claudeChatBodyText(body, benchOverride);
  }

  const anthropicHeaders: Record<string, string> = {
    "x-api-key": env.ANTHROPIC_API_KEY,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
  };
  const callerBetaHeader = request.headers.get("anthropic-beta");
  if (options.forwardsCallerBetaHeader && callerBetaHeader !== null) {
    anthropicHeaders["anthropic-beta"] = callerBetaHeader;
  }

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: anthropicHeaders,
    body,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[${options.routeName}] Anthropic API error ${response.status}: ${errorBody}`);
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
