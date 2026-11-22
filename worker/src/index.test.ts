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

    expect(withCachedSystemPrompt(requestBody)).toEqual({
      ...requestBody,
      system: [{ type: "text", text: "you're clicky", cache_control: { type: "ephemeral" } }],
    });
  });

  it("passes a body with no plain system prompt through unchanged", () => {
    const blockSystemBody = { system: [{ type: "text", text: "already blocks" }], messages: [] };

    expect(withCachedSystemPrompt(blockSystemBody)).toBe(blockSystemBody);
    expect(withCachedSystemPrompt({ system: "", messages: [] })).toEqual({ system: "", messages: [] });
    expect(withCachedSystemPrompt({ messages: [] })).toEqual({ messages: [] });
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

  it("passes a /chat request through as the app sent it, since the app marks its own cache breakpoint", async () => {
    const fetchMock = stubAnthropic();
    const chatBodyText = JSON.stringify({ system: "you're clicky", messages: [] });

    await worker.fetch(new Request("http://127.0.0.1:8787/chat", { method: "POST", body: chatBodyText }), testEnv);

    expect(fetchMock.mock.calls[0]?.[1].body).toBe(chatBodyText);
  });
});

describe("POST /v1/messages", () => {
  const messagesEnv = { ...testEnv, CLICKY_APP_SECRET: "app-secret" };
  const streamedReply = 'event: message_start\ndata: {"type":"message_start"}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n';

  function messagesRequest(headers: Record<string, string>, body: string): Request {
    return new Request("http://127.0.0.1:8787/v1/messages", { method: "POST", body, headers });
  }

  it("refuses a caller without the app secret before calling Anthropic", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    vi.spyOn(console, "error").mockImplementation(() => undefined);

    const response = await worker.fetch(messagesRequest({ "x-api-key": "caller-key" }, "{}"), messagesEnv);

    expect(response.status).toBe(401);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("sends the body to Anthropic unchanged with the Worker's key, and streams the reply back", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) =>
      new Response(streamedReply, { status: 200, headers: { "content-type": "text/event-stream" } }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const requestBodyText = JSON.stringify({ model: "claude-sonnet-5-5", stream: true, messages: [{ role: "user", content: "hi" }] });

    const response = await worker.fetch(
      messagesRequest(
        { "x-clicky-app-secret": "app-secret", "x-api-key": "caller-key", "anthropic-version": "2000-01-01", "anthropic-beta": "some-beta-2026-01-01" },
        requestBodyText,
      ),
      messagesEnv,
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("text/event-stream");
    expect(await response.text()).toBe(streamedReply);
    const [forwardedURL, forwardedInit] = fetchMock.mock.calls[0] ?? [];
    expect(forwardedURL).toBe("https://api.anthropic.com/v1/messages");
    expect(forwardedInit?.body).toBe(requestBodyText);
    expect(forwardedInit?.headers).toEqual({
      "x-api-key": "anthropic-key",
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
      "anthropic-beta": "some-beta-2026-01-01",
    });
  });

  it("forwards the anthropic-beta header on /v1/messages but never on /chat, which has no secret gate", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => new Response("{}", { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    const betaHeaders = { "x-clicky-app-secret": "app-secret", "anthropic-beta": "some-beta-2026-01-01" };

    await worker.fetch(new Request("http://127.0.0.1:8787/chat", { method: "POST", body: "{}", headers: betaHeaders }), messagesEnv);
    await worker.fetch(messagesRequest(betaHeaders, "{}"), messagesEnv);

    const [chatInit, messagesInit] = fetchMock.mock.calls.map((fetchCall) => fetchCall[1]);
    expect(chatInit?.headers).toEqual({ "x-api-key": "anthropic-key", "anthropic-version": "2023-06-01", "content-type": "application/json" });
    expect(messagesInit?.headers).toMatchObject({ "anthropic-beta": "some-beta-2026-01-01" });
  });

  it("passes an Anthropic error back with its status and body, so the SDK reports the real cause", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response('{"type":"error","error":{"type":"overloaded_error"}}', { status: 529 })));
    vi.spyOn(console, "error").mockImplementation(() => undefined);

    const response = await worker.fetch(messagesRequest({ "x-clicky-app-secret": "app-secret" }, "{}"), messagesEnv);

    expect(response.status).toBe(529);
    expect(await response.json()).toEqual({ type: "error", error: { type: "overloaded_error" } });
  });
});

describe("an error no route handles", () => {
  it("answers 500 with a fixed message, never the raw error text", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => {
      throw new TypeError("getaddrinfo ENOTFOUND api.anthropic.com");
    }));
    vi.spyOn(console, "error").mockImplementation(() => {});

    const response = await worker.fetch(new Request("http://127.0.0.1:8787/chat", { method: "POST", body: "{}" }), testEnv);

    expect(response.status).toBe(500);
    expect(await response.text()).not.toContain("ENOTFOUND");
  });
});

describe("POST /voice-command", () => {
  it("is routed to the voice command handler", async () => {
    vi.stubGlobal("fetch", vi.fn());

    const response = await worker.fetch(
      new Request("http://127.0.0.1:8787/voice-command", { method: "POST", body: JSON.stringify({ messages: [], tools: [] }) }),
      testEnv,
    );

    expect(response.status).toBe(400);
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

describe("the app secret on the gated routes", () => {
  const notionEnv = { ...testEnv, NOTION_API_KEY: "notion-key", CLICKY_APP_SECRET: "app-secret" };
  const notionPageBody = { title: "Catches", summary: "The ship was caught.", sections: [], sources: [] };

  function postTo(path: string, headers: Record<string, string>): Request {
    return new Request(`http://local${path}`, {
      method: "POST",
      body: JSON.stringify(notionPageBody),
      headers: { "content-type": "application/json", ...headers },
    });
  }

  it("refuses every gated route without the secret, with a wrong one, or when the Worker has none, before calling Notion", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    vi.spyOn(console, "error").mockImplementation(() => undefined);

    for (const path of ["/notion-page", "/study-guide", "/study-guide-status", "/v1/messages", "/try-it-item", "/room-wall"]) {
      expect((await worker.fetch(postTo(path, {}), notionEnv)).status).toBe(401);
      expect((await worker.fetch(postTo(path, { "x-clicky-app-secret": "app-secreT" }), notionEnv)).status).toBe(401);
      expect((await worker.fetch(postTo(path, { "x-clicky-app-secret": "app-secret" }), { ...notionEnv, CLICKY_APP_SECRET: undefined })).status).toBe(401);
      // With no secret on either side, both would hash the empty string and match, so an unset secret refuses on its own.
      expect((await worker.fetch(postTo(path, {}), { ...notionEnv, CLICKY_APP_SECRET: undefined })).status).toBe(401);
    }
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("writes the page when the request carries the secret", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) =>
      new Response(JSON.stringify({ id: "page-1", url: "https://www.notion.so/page-1" }), { status: 200 }),
    );
    vi.stubGlobal("fetch", fetchMock);

    const response = await worker.fetch(postTo("/notion-page", { "x-clicky-app-secret": "app-secret" }), notionEnv);

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ pageURL: "https://www.notion.so/page-1" });
    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://api.notion.com/v1/pages");
  });
});
