import { afterEach, describe, expect, it, vi } from "vitest";
import worker from "./index";
import { requestAnthropicReplyText, withCachedSystemPrompt } from "./anthropic";

const testEnv = {
  ANTHROPIC_API_KEY: "anthropic-key",
  ELEVENLABS_API_KEY: "elevenlabs-key",
  ELEVENLABS_VOICE_ID: "voice-id",
  ASSEMBLYAI_API_KEY: "assemblyai-key",
  OPENAI_API_KEY: "openai-key",
};

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("withCachedSystemPrompt", () => {
  it("puts a cache breakpoint on the system prompt and leaves the rest of the request as sent", () => {
    const requestBody = { model: "claude-sonnet-5-5", system: "you're clicky", messages: [{ role: "user", content: "hi" }] };

    const cachedRequestBody: unknown = JSON.parse(withCachedSystemPrompt(JSON.stringify(requestBody)));

    expect(cachedRequestBody).toEqual({
      ...requestBody,
      system: [{ type: "text", text: "you're clicky", cache_control: { type: "ephemeral" } }],
    });
  });

  it("passes a body with no plain system prompt through unchanged", () => {
    const blockSystemBody = JSON.stringify({ system: [{ type: "text", text: "already blocks" }], messages: [] });

    expect(withCachedSystemPrompt(blockSystemBody)).toBe(blockSystemBody);
    expect(withCachedSystemPrompt('{"messages":[]}')).toBe('{"messages":[]}');
    expect(withCachedSystemPrompt("not json")).toBe("not json");
  });
});

describe("system prompt caching on the Anthropic calls", () => {
  const cachedSystemPrompt = [{ type: "text", text: "you're clicky", cache_control: { type: "ephemeral" } }];

  function stubAnthropic() {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) =>
      new Response(JSON.stringify({ content: [{ type: "text", text: "{}" }], usage: {} }), {
        headers: { "content-type": "application/json" },
      }),
    );
    vi.stubGlobal("fetch", fetchMock);
    return fetchMock;
  }

  const sentSystemPrompt = (fetchMock: ReturnType<typeof stubAnthropic>): unknown =>
    JSON.parse(String(fetchMock.mock.calls[0]?.[1].body)).system;

  it("caches the system prompt of every route that uses the shared request helper", async () => {
    const fetchMock = stubAnthropic();

    await requestAnthropicReplyText("anthropic-key", "/judge-answer", { system: "you're clicky", messages: [] });

    expect(sentSystemPrompt(fetchMock)).toEqual(cachedSystemPrompt);
  });

  it("caches the system prompt of a /chat request the app sends", async () => {
    const fetchMock = stubAnthropic();

    await worker.fetch(
      new Request("http://127.0.0.1:8787/chat", { method: "POST", body: JSON.stringify({ system: "you're clicky", messages: [] }) }),
      testEnv,
    );

    expect(sentSystemPrompt(fetchMock)).toEqual(cachedSystemPrompt);
  });
});

describe("POST /tts", () => {
  it("streams from ElevenLabs in the output format the app asks for, and drops any other query value", async () => {
    const fetchMock = vi.fn(async (_url: URL) => new Response("audio", { headers: { "content-type": "audio/pcm" } }));
    vi.stubGlobal("fetch", fetchMock);

    const ttsRequest = (query: string) =>
      new Request(`http://127.0.0.1:8787/tts${query}`, { method: "POST", body: JSON.stringify({ text: "hello" }) });
    await worker.fetch(ttsRequest("?output_format=pcm_24000"), testEnv);
    await worker.fetch(ttsRequest("?output_format=../../voices"), testEnv);
    await worker.fetch(ttsRequest(""), testEnv);

    const forwardedURLs = fetchMock.mock.calls.map((fetchCall) => String(fetchCall[0]));
    expect(forwardedURLs).toEqual([
      "https://api.elevenlabs.io/v1/text-to-speech/voice-id/stream?output_format=pcm_24000",
      "https://api.elevenlabs.io/v1/text-to-speech/voice-id/stream",
      "https://api.elevenlabs.io/v1/text-to-speech/voice-id/stream",
    ]);
  });
});
