import { afterEach, describe, expect, it, vi } from "vitest";
import wranglerConfigText from "../wrangler.toml?raw";
import {
  anthropicBodyToGeminiChatBody,
  anthropicBodyToOpenAIResponsesBody,
  applyClaudeBenchOverride,
  benchModelOverride,
  claudeChatBodyText,
  configureBenchModelOverride,
  forwardChatToGemini,
  forwardChatToOpenAI,
  geminiChatCompletionToAnthropicMessage,
  geminiStreamToAnthropicStream,
  geminiUsageForLog,
  openAIResponseToAnthropicMessage,
  openAIStreamToAnthropicStream,
  requestBenchGeminiMessage,
  requestBenchOpenAIMessage,
  type GeminiBenchOverride,
  type OpenAIBenchOverride,
} from "./benchModelOverride";

afterEach(() => {
  configureBenchModelOverride({});
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

function gptOverride(overrides: Partial<OpenAIBenchOverride> = {}): OpenAIBenchOverride {
  return { provider: "openai", model: "gpt-test", apiKey: "openai-key", ...overrides };
}

function mappedBody(anthropicBody: unknown, override: OpenAIBenchOverride = gptOverride()): Record<string, unknown> {
  const mapping = anthropicBodyToOpenAIResponsesBody(anthropicBody, override);
  if (!mapping.ok) {
    throw new Error(`unsupported: ${mapping.unsupported}`);
  }
  return mapping.body;
}

describe("configureBenchModelOverride", () => {
  it("does nothing without BENCH_MODEL, even when the other vars are set", () => {
    const problem = configureBenchModelOverride({ BENCH_EFFORT: "high", BENCH_SERVICE_TIER: "ultrafast", OPENAI_API_KEY: "openai-key" });

    expect(problem).toBeUndefined();
    expect(benchModelOverride()).toBeUndefined();
  });

  it("does nothing for an empty BENCH_MODEL, as from --var BENCH_MODEL: with no value", () => {
    expect(configureBenchModelOverride({ BENCH_MODEL: "", OPENAI_API_KEY: "openai-key" })).toBeUndefined();
    expect(configureBenchModelOverride({ BENCH_MODEL: "  " })).toBeUndefined();
    expect(benchModelOverride()).toBeUndefined();
  });

  it("forgets the override of an earlier request, so one request's vars never reach the next", () => {
    configureBenchModelOverride({ BENCH_MODEL: "claude-haiku-5-5" });
    expect(benchModelOverride()).toEqual({ provider: "anthropic", model: "claude-haiku-5-5", effort: undefined });

    configureBenchModelOverride({});

    expect(benchModelOverride()).toBeUndefined();
  });

  it("keeps a Claude model and its effort, and refuses a service tier, which only OpenAI has", () => {
    expect(configureBenchModelOverride({ BENCH_MODEL: "claude-opus-5-5", BENCH_EFFORT: "max" })).toBeUndefined();
    expect(benchModelOverride()).toEqual({ provider: "anthropic", model: "claude-opus-5-5", effort: "max" });

    expect(configureBenchModelOverride({ BENCH_MODEL: "claude-opus-5-5", BENCH_EFFORT: "none" })).toContain("BENCH_EFFORT");
    expect(configureBenchModelOverride({ BENCH_MODEL: "claude-opus-5-5", BENCH_SERVICE_TIER: "ultrafast" })).toContain("BENCH_SERVICE_TIER");
    expect(benchModelOverride()).toBeUndefined();
  });

  it("keeps a GPT model with the key, effort, and tier, and refuses a missing key or a wrong value", () => {
    expect(
      configureBenchModelOverride({ BENCH_MODEL: "gpt-6-luna", BENCH_EFFORT: "none", BENCH_SERVICE_TIER: "ultrafast", OPENAI_API_KEY: "openai-key" }),
    ).toBeUndefined();
    expect(benchModelOverride()).toEqual({ provider: "openai", model: "gpt-6-luna", apiKey: "openai-key", effort: "none", serviceTier: "ultrafast" });

    expect(configureBenchModelOverride({ BENCH_MODEL: "gpt-6-luna" })).toContain("OPENAI_API_KEY");
    expect(configureBenchModelOverride({ BENCH_MODEL: "gpt-6-luna", OPENAI_API_KEY: "k", BENCH_EFFORT: "max" })).toContain("BENCH_EFFORT");
    expect(configureBenchModelOverride({ BENCH_MODEL: "gpt-6-luna", OPENAI_API_KEY: "k", BENCH_SERVICE_TIER: "Ultra Fast" })).toContain("BENCH_SERVICE_TIER");
    expect(benchModelOverride()).toBeUndefined();
  });

  it("refuses a model that is none of Claude, GPT, or Gemini", () => {
    expect(configureBenchModelOverride({ BENCH_MODEL: "llama-4" })).toContain("claude-, gpt-, or gemini-");
    expect(benchModelOverride()).toBeUndefined();
  });

  it("is never set in wrangler.toml, so a deployed Worker cannot start with an override", () => {
    expect(wranglerConfigText).not.toContain("BENCH_");
  });
});

describe("applyClaudeBenchOverride", () => {
  const claudeOverride = { provider: "anthropic", model: "claude-haiku-5-5" } as const;

  it("replaces only the model when no effort is set", () => {
    const requestBody = { model: "claude-sonnet-5-5", max_tokens: 10, output_config: { effort: "low", format: { type: "json_schema" } }, messages: [] };

    expect(applyClaudeBenchOverride(requestBody, claudeOverride)).toEqual({ ...requestBody, model: "claude-haiku-5-5" });
  });

  it("replaces the effort and keeps the rest of output_config", () => {
    const requestBody = { model: "claude-sonnet-5-5", output_config: { effort: "low", format: { type: "json_schema" } }, messages: [] };

    expect(applyClaudeBenchOverride(requestBody, { ...claudeOverride, effort: "high" })).toEqual({
      ...requestBody,
      model: "claude-haiku-5-5",
      output_config: { effort: "high", format: { type: "json_schema" } },
    });
  });

  it("drops thinking off for a model that cannot turn it off, and keeps it for Haiku", () => {
    const requestBody = { model: "claude-haiku-5-5", thinking: { type: "disabled" }, output_config: { effort: "low" }, messages: [] };

    expect(applyClaudeBenchOverride(requestBody, { provider: "anthropic", model: "claude-opus-5-5" })).toEqual({
      model: "claude-opus-5-5",
      output_config: { effort: "low" },
      messages: [],
    });
    expect(applyClaudeBenchOverride(requestBody, claudeOverride)).toEqual(requestBody);
  });

  it("adds output_config when the route had none and an effort is set", () => {
    expect(applyClaudeBenchOverride({ model: "m", messages: [] }, { ...claudeOverride, effort: "low" })).toEqual({
      model: "claude-haiku-5-5",
      messages: [],
      output_config: { effort: "low" },
    });
  });

  it("leaves a body that is not an object as it is", () => {
    expect(applyClaudeBenchOverride("text", claudeOverride)).toBe("text");
  });

  it("rewrites a /chat body's model, and leaves text that is not a JSON object as sent", () => {
    expect(JSON.parse(claudeChatBodyText('{"model":"claude-sonnet-5-5","stream":true}', claudeOverride))).toEqual({
      model: "claude-haiku-5-5",
      stream: true,
    });
    expect(claudeChatBodyText("not json", claudeOverride)).toBe("not json");
    expect(claudeChatBodyText("[1]", claudeOverride)).toBe("[1]");
  });
});

describe("anthropicBodyToOpenAIResponsesBody", () => {
  it("puts a string system prompt in instructions and joins system blocks, dropping the cache breakpoint", () => {
    expect(mappedBody({ system: "you are clicky", messages: [] }).instructions).toBe("you are clicky");
    expect(
      mappedBody({
        system: [
          { type: "text", text: "first", cache_control: { type: "ephemeral" } },
          { type: "text", text: "second" },
        ],
        messages: [],
      }).instructions,
    ).toBe("first\n\nsecond");
    expect(mappedBody({ messages: [] })).not.toHaveProperty("instructions");
  });

  it("maps text and base64 image blocks, and string content, by role", () => {
    const body = mappedBody({
      messages: [
        { role: "user", content: "hello" },
        { role: "assistant", content: "hi there" },
        {
          role: "user",
          content: [
            { type: "image", source: { type: "base64", media_type: "image/png", data: "QUJD" } },
            { type: "text", text: "what is this" },
          ],
        },
      ],
    });

    expect(body.input).toEqual([
      { role: "user", content: [{ type: "input_text", text: "hello" }] },
      { role: "assistant", content: [{ type: "output_text", text: "hi there" }] },
      {
        role: "user",
        content: [
          { type: "input_image", image_url: "data:image/png;base64,QUJD", detail: "high" },
          { type: "input_text", text: "what is this" },
        ],
      },
    ]);
  });

  it("maps max_tokens to max_output_tokens and sets the model and the service tier", () => {
    const body = mappedBody({ max_tokens: 1024, messages: [] }, gptOverride({ model: "gpt-6-sol", serviceTier: "ultrafast" }));

    expect(body).toMatchObject({ model: "gpt-6-sol", max_output_tokens: 1024, service_tier: "ultrafast" });
    expect(mappedBody({ messages: [] })).not.toHaveProperty("service_tier");
    expect(mappedBody({ messages: [] })).not.toHaveProperty("max_output_tokens");
  });

  it("maps the route's effort, with max becoming xhigh, and sets none when the route sends none", () => {
    expect(mappedBody({ output_config: { effort: "low" }, messages: [] }).reasoning).toEqual({ effort: "low" });
    expect(mappedBody({ output_config: { effort: "max" }, messages: [] }).reasoning).toEqual({ effort: "xhigh" });
    expect(mappedBody({ messages: [] })).not.toHaveProperty("reasoning");
  });

  it("lets BENCH_EFFORT win over the route's effort", () => {
    const body = mappedBody({ output_config: { effort: "low" }, messages: [] }, gptOverride({ effort: "high" }));

    expect(body.reasoning).toEqual({ effort: "high" });
  });

  it("maps a json_schema format to a strict text format", () => {
    const schema = { type: "object", additionalProperties: false, properties: { verdict: { type: "string" } }, required: ["verdict"] };

    const body = mappedBody({ output_config: { effort: "low", format: { type: "json_schema", schema } }, messages: [] });

    expect(body.text).toEqual({ format: { type: "json_schema", name: "reply", schema, strict: true } });
  });

  it.each([
    ["a tool_result block", "tool_result", { messages: [{ role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: "ok" }] }] }],
    ["a tool_use block", "tool_use", { messages: [{ role: "assistant", content: [{ type: "tool_use", id: "t1", name: "x", input: {} }] }] }],
    ["a thinking block", "thinking", { messages: [{ role: "assistant", content: [{ type: "thinking", thinking: "..." }] }] }],
    ["an image that is not base64", "not base64", { messages: [{ role: "user", content: [{ type: "image", source: { type: "url", url: "https://x" } }] }] }],
    ["a tools list", "tools", { messages: [{ role: "user", content: "x" }], tools: [{ name: "x", input_schema: { type: "object" } }] }],
    ["a tool_choice", "tools", { messages: [{ role: "user", content: "x" }], tool_choice: { type: "any" } }],
  ])("reports %s as unsupported instead of guessing", (_unsupportedThing, expectedMention, anthropicBody) => {
    const mapping = anthropicBodyToOpenAIResponsesBody(anthropicBody, gptOverride());

    expect(mapping.ok).toBe(false);
    if (!mapping.ok) {
      expect(mapping.unsupported).toContain(expectedMention);
    }
  });

});

describe("openAIResponseToAnthropicMessage", () => {
  const usage = { input_tokens: 120, input_tokens_details: { cached_tokens: 100 }, output_tokens: 30, output_tokens_details: { reasoning_tokens: 10 } };

  it("maps output text to a text block, drops reasoning items, and reports the token counts", () => {
    const reply = openAIResponseToAnthropicMessage({
      id: "resp_1",
      model: "gpt-6-luna-2026-11-12",
      status: "completed",
      service_tier: "ultrafast",
      output: [
        { type: "reasoning", summary: [] },
        { type: "message", role: "assistant", content: [{ type: "output_text", text: '{"verdict":"correct"}' }] },
      ],
      usage,
    });

    expect(reply).toEqual({
      ok: true,
      message: {
        id: "resp_1",
        type: "message",
        role: "assistant",
        model: "gpt-6-luna-2026-11-12",
        content: [{ type: "text", text: '{"verdict":"correct"}' }],
        stop_reason: "end_turn",
        usage: { input_tokens: 120, output_tokens: 30 },
      },
    });
  });

  it("maps an output limit to max_tokens and a content filter or a refusal to refusal", () => {
    const stopReasonOf = (response: Record<string, unknown>) => {
      const reply = openAIResponseToAnthropicMessage({ output: [], ...response });
      return reply.ok ? reply.message.stop_reason : reply.error;
    };

    expect(stopReasonOf({ status: "incomplete", incomplete_details: { reason: "max_output_tokens" } })).toBe("max_tokens");
    expect(stopReasonOf({ status: "incomplete", incomplete_details: { reason: "content_filter" } })).toBe("refusal");
    expect(stopReasonOf({ output: [{ type: "message", content: [{ type: "refusal", refusal: "I can't help" }] }] })).toBe("refusal");
    expect(stopReasonOf({})).toBe("end_turn");
  });

  it("reports a failed response and a reply with no output list as errors", () => {
    expect(openAIResponseToAnthropicMessage({ status: "failed", error: { message: "server_error" }, output: [] })).toEqual({ ok: false, error: "server_error" });
    expect(openAIResponseToAnthropicMessage({ status: "completed" })).toEqual({ ok: false, error: "OpenAI response had no output list" });
  });
});

describe("requestBenchOpenAIMessage", () => {
  const completedReply = {
    model: "gpt-test",
    status: "completed",
    output: [{ type: "message", content: [{ type: "output_text", text: "{}" }] }],
    usage: { input_tokens: 1, output_tokens: 1 },
  };

  function stubOpenAI(...replies: Response[]) {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => replies.shift() ?? new Response(JSON.stringify(completedReply)));
    vi.stubGlobal("fetch", fetchMock);
    return fetchMock;
  }

  const sentBodies = (fetchMock: ReturnType<typeof stubOpenAI>) => fetchMock.mock.calls.map((fetchCall) => JSON.parse(String(fetchCall[1].body)));

  it("posts the mapped body to the Responses API with the key, and returns the mapped reply", async () => {
    const fetchMock = stubOpenAI();

    const reply = await requestBenchOpenAIMessage(gptOverride({ serviceTier: "ultrafast" }), "/test-route", { max_tokens: 5, messages: [{ role: "user", content: "hi" }] });

    const [url, init] = fetchMock.mock.calls[0] ?? [];
    expect(url).toBe("https://api.openai.com/v1/responses");
    expect(init?.headers).toEqual({ authorization: "Bearer openai-key", "content-type": "application/json" });
    expect(sentBodies(fetchMock)[0]).toEqual({
      model: "gpt-test",
      input: [{ role: "user", content: [{ type: "input_text", text: "hi" }] }],
      max_output_tokens: 5,
      service_tier: "ultrafast",
    });
    expect(reply.ok && reply.message.content).toEqual([{ type: "text", text: "{}" }]);
  });

  it("answers 501 without calling OpenAI for a request it cannot port", async () => {
    const fetchMock = stubOpenAI();

    const reply = await requestBenchOpenAIMessage(gptOverride(), "/test-route", {
      messages: [{ role: "user", content: [{ type: "tool_result", tool_use_id: "t", content: "ok" }] }],
    });

    expect(reply).toMatchObject({ ok: false, status: 501 });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("passes an OpenAI error back with its status and text", async () => {
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    stubOpenAI(new Response('{"error":{"message":"bad schema"}}', { status: 400 }));

    const reply = await requestBenchOpenAIMessage(gptOverride(), "/test-route", { messages: [] });

    expect(reply).toEqual({ ok: false, status: 400, error: '{"error":{"message":"bad schema"}}' });
  });

  it("answers 502 when the fetch itself fails", async () => {
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.stubGlobal("fetch", vi.fn(async () => { throw new TypeError("network down"); }));

    expect(await requestBenchOpenAIMessage(gptOverride(), "/test-route", { messages: [] })).toEqual({ ok: false, status: 502, error: "OpenAI could not be reached" });
  });
});

describe("openAIStreamToAnthropicStream", () => {
  const encoder = new TextEncoder();

  function openAIEvent(eventPayload: Record<string, unknown>): string {
    return `event: ${String(eventPayload.type)}\ndata: ${JSON.stringify(eventPayload)}\n\n`;
  }

  /** Feeds the text through the translator in chunks of the given size, so events split across chunks. */
  async function translate(openAIStreamText: string, chunkSize: number): Promise<Array<Record<string, unknown>>> {
    const bytes = encoder.encode(openAIStreamText);
    const upstream = new ReadableStream<Uint8Array>({
      start(controller) {
        for (let offset = 0; offset < bytes.length; offset += chunkSize) {
          controller.enqueue(bytes.slice(offset, offset + chunkSize));
        }
        controller.close();
      },
    });
    const translatedText = await new Response(upstream.pipeThrough(openAIStreamToAnthropicStream())).text();
    return translatedText
      .split("\n\n")
      .filter((eventBlock) => eventBlock.length > 0)
      .map((eventBlock) => {
        const [eventLine, dataLine] = eventBlock.split("\n");
        const payload = JSON.parse(dataLine.replace("data: ", ""));
        expect(eventLine).toBe(`event: ${payload.type}`);
        return payload;
      });
  }

  const usage = { input_tokens: 900, input_tokens_details: { cached_tokens: 512 }, output_tokens: 40 };
  const completedStream =
    openAIEvent({ type: "response.created", response: { id: "resp_1", model: "gpt-6-luna" } }) +
    openAIEvent({ type: "response.in_progress", response: {} }) +
    openAIEvent({ type: "response.output_text.delta", delta: "see that " }) +
    openAIEvent({ type: "response.output_text.delta", delta: "button [POINT:1200,60:download pdf]" }) +
    openAIEvent({ type: "response.output_text.done", text: "see that button" }) +
    openAIEvent({ type: "response.completed", response: { usage, service_tier: "ultrafast" } });

  it.each([1, 7, 4096])("turns text deltas and the final usage into Anthropic events, in chunks of %i bytes", async (chunkSize) => {
    const events = await translate(completedStream, chunkSize);

    expect(events.map((streamEvent) => streamEvent.type)).toEqual([
      "message_start",
      "content_block_start",
      "content_block_delta",
      "content_block_delta",
      "content_block_stop",
      "message_delta",
      "message_stop",
    ]);
    expect(events[0]).toMatchObject({ message: { id: "resp_1", model: "gpt-6-luna", role: "assistant" } });
    expect(events.filter((streamEvent) => streamEvent.type === "content_block_delta").map((streamEvent) => streamEvent.delta)).toEqual([
      { type: "text_delta", text: "see that " },
      { type: "text_delta", text: "button [POINT:1200,60:download pdf]" },
    ]);
    expect(events[5]).toEqual({
      type: "message_delta",
      delta: { stop_reason: "end_turn", stop_sequence: null },
      usage: { ...usage, service_tier: "ultrafast" },
    });
  });

  it("starts the message at the first delta when the created event never arrived", async () => {
    const events = await translate(openAIEvent({ type: "response.output_text.delta", delta: "hi" }), 4096);

    expect(events.map((streamEvent) => streamEvent.type)).toEqual(["message_start", "content_block_start", "content_block_delta"]);
  });

  it("reports an output limit as max_tokens", async () => {
    const events = await translate(
      openAIEvent({ type: "response.created", response: { model: "gpt-6-luna" } }) +
        openAIEvent({ type: "response.incomplete", response: { incomplete_details: { reason: "max_output_tokens" }, usage } }),
      4096,
    );

    expect(events.find((streamEvent) => streamEvent.type === "message_delta")).toMatchObject({ delta: { stop_reason: "max_tokens" } });
  });

  it("answers a failed response with one error event and ignores what follows", async () => {
    const events = await translate(
      openAIEvent({ type: "response.created", response: { model: "gpt-6-luna" } }) +
        openAIEvent({ type: "response.failed", response: { error: { message: "overloaded" } } }) +
        openAIEvent({ type: "response.output_text.delta", delta: "late" }),
      4096,
    );

    expect(events.map((streamEvent) => streamEvent.type)).toEqual(["message_start", "content_block_start", "error"]);
    expect(events[2]).toMatchObject({ error: { type: "api_error", message: "overloaded" } });
  });

  it("reads CRLF line endings and skips the DONE marker", async () => {
    const events = await translate(completedStream.replaceAll("\n", "\r\n") + "data: [DONE]\r\n\r\n", 5);

    expect(events.map((streamEvent) => streamEvent.type)).toContain("message_stop");
  });
});

describe("forwardChatToOpenAI", () => {
  const chatBody = {
    model: "claude-sonnet-5-5",
    max_tokens: 1024,
    stream: true,
    output_config: { effort: "low" },
    system: [{ type: "text", text: "you're clicky", cache_control: { type: "ephemeral" } }],
    messages: [{ role: "user", content: [{ type: "text", text: "hi" }] }],
  };

  it("streams the answer back as Anthropic events from a body sent to the Responses API with stream on", async () => {
    const upstreamStream = 'data: {"type":"response.output_text.delta","delta":"hello"}\n\ndata: {"type":"response.completed","response":{"usage":{"output_tokens":2}}}\n\n';
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => new Response(upstreamStream, { headers: { "content-type": "text/event-stream" } }));
    vi.stubGlobal("fetch", fetchMock);

    const response = await forwardChatToOpenAI(gptOverride({ model: "gpt-6-sol" }), JSON.stringify(chatBody));

    expect(response.headers.get("content-type")).toBe("text/event-stream");
    expect(await response.text()).toContain('"text_delta","text":"hello"');
    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://api.openai.com/v1/responses");
    expect(JSON.parse(String(fetchMock.mock.calls[0]?.[1].body))).toEqual({
      model: "gpt-6-sol",
      instructions: "you're clicky",
      input: [{ role: "user", content: [{ type: "input_text", text: "hi" }] }],
      max_output_tokens: 1024,
      reasoning: { effort: "low" },
      stream: true,
    });
  });

  it("passes an OpenAI error back with its status", async () => {
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.stubGlobal("fetch", vi.fn(async () => new Response('{"error":"rate limited"}', { status: 429 })));

    const response = await forwardChatToOpenAI(gptOverride(), JSON.stringify(chatBody));

    expect(response.status).toBe(429);
    expect(await response.text()).toBe('{"error":"rate limited"}');
  });

  it("answers 400 for a body that is not JSON and 501 for one it cannot port, without calling OpenAI", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    expect((await forwardChatToOpenAI(gptOverride(), "not json")).status).toBe(400);
    const unsupportedBody = { messages: [{ role: "user", content: [{ type: "tool_result", tool_use_id: "t", content: "x" }] }] };
    expect((await forwardChatToOpenAI(gptOverride(), JSON.stringify(unsupportedBody))).status).toBe(501);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

// ---------- Gemini ----------

function geminiOverride(overrides: Partial<GeminiBenchOverride> = {}): GeminiBenchOverride {
  return { provider: "gemini", model: "gemini-test", apiKey: "gemini-key", ...overrides };
}

function geminiMappedBody(anthropicBody: unknown, override: GeminiBenchOverride = geminiOverride()): Record<string, unknown> {
  const mapping = anthropicBodyToGeminiChatBody(anthropicBody, override);
  if (!mapping.ok) {
    throw new Error(`unsupported: ${mapping.unsupported}`);
  }
  return mapping.body;
}

const geminiChatCompletionsURL = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions";

describe("configureBenchModelOverride for Gemini", () => {
  it("keeps a Gemini model with the key and effort", () => {
    expect(configureBenchModelOverride({ BENCH_MODEL: "gemini-4-neon", BENCH_EFFORT: "xhigh", GEMINI_API_KEY: " gemini-key " })).toBeUndefined();
    expect(benchModelOverride()).toEqual({ provider: "gemini", model: "gemini-4-neon", apiKey: "gemini-key", effort: "xhigh" });
  });

  it("names GEMINI_API_KEY when it is missing or empty, and never reads OPENAI_API_KEY instead", () => {
    expect(configureBenchModelOverride({ BENCH_MODEL: "gemini-4-neon", OPENAI_API_KEY: "openai-key" })).toBe("A gemini-* BENCH_MODEL needs GEMINI_API_KEY");
    expect(configureBenchModelOverride({ BENCH_MODEL: "gemini-4-neon", GEMINI_API_KEY: "  " })).toBe("A gemini-* BENCH_MODEL needs GEMINI_API_KEY");
    expect(benchModelOverride()).toBeUndefined();
  });

  it("refuses a service tier, which Gemini has none of here, and an effort it does not know", () => {
    expect(configureBenchModelOverride({ BENCH_MODEL: "gemini-4-neon", GEMINI_API_KEY: "k", BENCH_SERVICE_TIER: "ultrafast" })).toContain("BENCH_SERVICE_TIER");
    expect(configureBenchModelOverride({ BENCH_MODEL: "gemini-4-neon", GEMINI_API_KEY: "k", BENCH_EFFORT: "none" })).toContain("BENCH_EFFORT");
    expect(configureBenchModelOverride({ BENCH_MODEL: "gemini-4-neon", GEMINI_API_KEY: "k", BENCH_EFFORT: "max" })).toContain("BENCH_EFFORT");
    expect(benchModelOverride()).toBeUndefined();
  });
});

describe("anthropicBodyToGeminiChatBody", () => {
  it("puts the system prompt first as a system message, joins system blocks, and drops the cache breakpoint", () => {
    const body = geminiMappedBody({
      system: [
        { type: "text", text: "you're clicky", cache_control: { type: "ephemeral" } },
        { type: "text", text: "be brief" },
      ],
      messages: [{ role: "user", content: "hi" }],
    });

    expect(body.messages).toEqual([
      { role: "system", content: "you're clicky\n\nbe brief" },
      { role: "user", content: [{ type: "text", text: "hi" }] },
    ]);
  });

  it("maps a base64 image to an image_url data URL and keeps the text beside it, with max_tokens and the model", () => {
    const body = geminiMappedBody({
      max_tokens: 1500,
      messages: [
        {
          role: "user",
          content: [
            { type: "image", source: { type: "base64", media_type: "image/jpeg", data: "QUJD" } },
            { type: "text", text: "find the subject" },
          ],
        },
      ],
    });

    expect(body).toEqual({
      model: "gemini-test",
      messages: [
        {
          role: "user",
          content: [
            { type: "image_url", image_url: { url: "data:image/jpeg;base64,QUJD" } },
            { type: "text", text: "find the subject" },
          ],
        },
      ],
      max_tokens: 1500,
    });
  });

  it("maps a json_schema format to a strict response_format, and sends no OpenAI-only fields", () => {
    const schema = { type: "object", properties: { verdict: { type: "string" } }, required: ["verdict"], additionalProperties: false };

    const body = geminiMappedBody({ output_config: { format: { type: "json_schema", schema } }, messages: [{ role: "user", content: "x" }] });

    expect(body.response_format).toEqual({ type: "json_schema", json_schema: { name: "reply", schema, strict: true } });
    expect(body).not.toHaveProperty("text");
    expect(body).not.toHaveProperty("service_tier");
  });

  it("maps the route's effort to reasoning_effort, with max as xhigh and minimal as low", () => {
    const requestWithEffort = (effort: string) => ({ output_config: { effort }, messages: [{ role: "user", content: "x" }] });

    expect(geminiMappedBody(requestWithEffort("medium")).reasoning_effort).toBe("medium");
    expect(geminiMappedBody(requestWithEffort("max")).reasoning_effort).toBe("xhigh");
    expect(geminiMappedBody(requestWithEffort("medium"), geminiOverride({ effort: "minimal" })).reasoning_effort).toBe("low");
    expect(geminiMappedBody({ messages: [{ role: "user", content: "x" }] })).not.toHaveProperty("reasoning_effort");
  });

  it("reports an image that is not base64, tool blocks, and other blocks as unsupported", () => {
    const userRequest = (content: unknown) => ({ messages: [{ role: "user", content }] });

    expect(anthropicBodyToGeminiChatBody(userRequest([{ type: "image", source: { type: "url", url: "https://x" } }]), geminiOverride())).toEqual({
      ok: false,
      unsupported: "an image that is not base64",
    });
    expect(anthropicBodyToGeminiChatBody(userRequest([{ type: "tool_result", tool_use_id: "t", content: "ok" }]), geminiOverride())).toEqual({
      ok: false,
      unsupported: "a tool_result block",
    });
    expect(
      anthropicBodyToGeminiChatBody({ messages: [{ role: "assistant", content: [{ type: "tool_use", id: "t", name: "x", input: {} }] }] }, geminiOverride()),
    ).toEqual({ ok: false, unsupported: "a tool_use block" });
    expect(anthropicBodyToGeminiChatBody(userRequest([{ type: "document" }]), geminiOverride())).toEqual({ ok: false, unsupported: "a document block" });
    expect(anthropicBodyToGeminiChatBody({ ...userRequest("x"), tools: [{ name: "x", input_schema: { type: "object" } }] }, geminiOverride())).toEqual({
      ok: false,
      unsupported: "a request with tools",
    });
    expect(
      anthropicBodyToGeminiChatBody({ messages: [{ role: "assistant", content: [{ type: "thinking", thinking: "" }] }] }, geminiOverride()),
    ).toEqual({ ok: false, unsupported: "a thinking block" });
  });
});

describe("geminiChatCompletionToAnthropicMessage", () => {
  const usage = { prompt_tokens: 900, completion_tokens: 40, total_tokens: 940, prompt_tokens_details: { cached_tokens: 512 } };

  function reply(message: Record<string, unknown>, finishReason: string | null = "stop", replyUsage: unknown = usage) {
    return { id: "chatcmpl-1", model: "gemini-4-neon", choices: [{ index: 0, message: { role: "assistant", ...message }, finish_reason: finishReason }], usage: replyUsage };
  }

  it("maps the answer text to a text block, and the usage to the field names the benchmark reads", () => {
    const mapping = geminiChatCompletionToAnthropicMessage(reply({ content: '{"verdict":"correct"}' }));

    expect(mapping).toEqual({
      ok: true,
      usageForLog: { input_tokens: 900, input_tokens_details: { cached_tokens: 512 }, output_tokens: 40 },
      message: {
        id: "chatcmpl-1",
        type: "message",
        role: "assistant",
        model: "gemini-4-neon",
        content: [{ type: "text", text: '{"verdict":"correct"}' }],
        stop_reason: "end_turn",
        usage: { input_tokens: 900, output_tokens: 40 },
      },
    });
  });

  it("maps length to max_tokens and a content filter or a refusal to refusal", () => {
    const stopReasonOf = (message: Record<string, unknown>, finishReason: string) => {
      const mapping = geminiChatCompletionToAnthropicMessage(reply(message, finishReason));
      return mapping.ok ? mapping.message.stop_reason : mapping.error;
    };

    expect(stopReasonOf({ content: "{" }, "length")).toBe("max_tokens");
    expect(stopReasonOf({ content: null }, "content_filter")).toBe("refusal");
    expect(stopReasonOf({ content: null, refusal: "I cannot help with that." }, "stop")).toBe("refusal");
  });

  it("reports a reply with no choices as an error", () => {
    expect(geminiChatCompletionToAnthropicMessage({ choices: [] })).toEqual({ ok: false, error: "Gemini response had no choices" });
    expect(geminiChatCompletionToAnthropicMessage({ error: { message: "bad" } })).toEqual({ ok: false, error: "Gemini response had no choices list" });
  });
});

describe("geminiUsageForLog", () => {
  it("reads cached tokens from prompt_tokens_details, and counts none when there are no details", () => {
    expect(geminiUsageForLog({ prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 })).toEqual({
      input_tokens: 10,
      input_tokens_details: { cached_tokens: 0 },
      output_tokens: 5,
    });
  });

  it("bills thinking as output when completion_tokens leaves it out, and trusts completion_tokens when it already counts it", () => {
    expect(geminiUsageForLog({ prompt_tokens: 100, completion_tokens: 20, total_tokens: 420 }).output_tokens).toBe(320);
    expect(geminiUsageForLog({ prompt_tokens: 100, completion_tokens: 320, total_tokens: 420 }).output_tokens).toBe(320);
    expect(geminiUsageForLog(undefined)).toEqual({ input_tokens: 0, input_tokens_details: { cached_tokens: 0 }, output_tokens: 0 });
  });
});

describe("requestBenchGeminiMessage", () => {
  const completedReply = {
    id: "c1",
    model: "gemini-test",
    choices: [{ message: { role: "assistant", content: "{}" }, finish_reason: "stop" }],
    usage: { prompt_tokens: 7, completion_tokens: 3, total_tokens: 10, prompt_tokens_details: { cached_tokens: 2 } },
  };

  it("posts the mapped body to the Chat Completions endpoint with the key, and returns the message with a usage-shaped reply for the log", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => new Response(JSON.stringify(completedReply)));
    vi.stubGlobal("fetch", fetchMock);

    const reply = await requestBenchGeminiMessage(geminiOverride(), "/test-route", { max_tokens: 5, messages: [{ role: "user", content: "hi" }] });

    const [url, init] = fetchMock.mock.calls[0] ?? [];
    expect(url).toBe(geminiChatCompletionsURL);
    expect(init?.headers).toEqual({ authorization: "Bearer gemini-key", "content-type": "application/json" });
    expect(JSON.parse(String(init?.body))).toEqual({
      model: "gemini-test",
      messages: [{ role: "user", content: [{ type: "text", text: "hi" }] }],
      max_tokens: 5,
    });
    expect(reply.ok && reply.message.content).toEqual([{ type: "text", text: "{}" }]);
    expect(reply.ok && reply.responseJSON).toEqual({
      model: "gemini-test",
      usage: { input_tokens: 7, input_tokens_details: { cached_tokens: 2 }, output_tokens: 3 },
    });
  });

  it("answers 501 without calling Gemini for a request it cannot port", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const reply = await requestBenchGeminiMessage(geminiOverride(), "/test-route", {
      messages: [{ role: "assistant", content: [{ type: "tool_use", id: "t", name: "x", input: {} }] }],
    });

    expect(reply).toEqual({ ok: false, status: 501, error: "BENCH_MODEL gemini-test cannot take a tool_use block" });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("passes a Gemini error back with its status and text, and answers 502 when the fetch fails or the body is not JSON", async () => {
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    const body = { messages: [{ role: "user", content: "hi" }] };

    vi.stubGlobal("fetch", vi.fn(async () => new Response('[{"error":{"message":"quota"}}]', { status: 429 })));
    expect(await requestBenchGeminiMessage(geminiOverride(), "/test-route", body)).toEqual({ ok: false, status: 429, error: '[{"error":{"message":"quota"}}]' });

    vi.stubGlobal("fetch", vi.fn(async () => Promise.reject(new Error("offline"))));
    expect(await requestBenchGeminiMessage(geminiOverride(), "/test-route", body)).toEqual({ ok: false, status: 502, error: "Gemini could not be reached" });

    vi.stubGlobal("fetch", vi.fn(async () => new Response("<html>")));
    expect(await requestBenchGeminiMessage(geminiOverride(), "/test-route", body)).toEqual({ ok: false, status: 502, error: "Gemini returned a body that was not JSON" });
  });
});

describe("geminiStreamToAnthropicStream", () => {
  const encoder = new TextEncoder();

  function geminiChunk(chunkPayload: Record<string, unknown>): string {
    return `data: ${JSON.stringify(chunkPayload)}\n\n`;
  }

  async function translate(geminiStreamText: string, chunkSize: number): Promise<Array<Record<string, unknown>>> {
    const bytes = encoder.encode(geminiStreamText);
    const upstream = new ReadableStream<Uint8Array>({
      start(controller) {
        for (let offset = 0; offset < bytes.length; offset += chunkSize) {
          controller.enqueue(bytes.slice(offset, offset + chunkSize));
        }
        controller.close();
      },
    });
    const translatedText = await new Response(upstream.pipeThrough(geminiStreamToAnthropicStream())).text();
    return translatedText
      .split("\n\n")
      .filter((eventBlock) => eventBlock.length > 0)
      .map((eventBlock) => {
        const [eventLine, dataLine] = eventBlock.split("\n");
        const payload = JSON.parse(dataLine.replace("data: ", ""));
        expect(eventLine).toBe(`event: ${payload.type}`);
        return payload;
      });
  }

  const usage = { prompt_tokens: 900, completion_tokens: 30, total_tokens: 970, prompt_tokens_details: { cached_tokens: 512 } };
  // The finish chunk comes before the usage chunk, which has no choices, and [DONE] ends the stream.
  const completedStream =
    geminiChunk({ id: "c1", model: "gemini-4-neon", choices: [{ index: 0, delta: { role: "assistant", content: "see that " } }] }) +
    geminiChunk({ id: "c1", model: "gemini-4-neon", choices: [{ index: 0, delta: { content: "button [POINT:1200,60:download pdf]" } }] }) +
    geminiChunk({ id: "c1", model: "gemini-4-neon", choices: [{ index: 0, delta: { content: null }, finish_reason: "stop" }] }) +
    geminiChunk({ id: "c1", model: "gemini-4-neon", choices: [], usage }) +
    "data: [DONE]\n\n";

  it.each([1, 7, 4096])("turns text deltas, the finish reason, and the usage chunk into Anthropic events, in chunks of %i bytes", async (chunkSize) => {
    const events = await translate(completedStream, chunkSize);

    expect(events.map((streamEvent) => streamEvent.type)).toEqual([
      "message_start",
      "content_block_start",
      "content_block_delta",
      "content_block_delta",
      "content_block_stop",
      "message_delta",
      "message_stop",
    ]);
    expect(events[0]).toMatchObject({ message: { id: "c1", model: "gemini-4-neon", role: "assistant" } });
    expect(events.filter((streamEvent) => streamEvent.type === "content_block_delta").map((streamEvent) => streamEvent.delta)).toEqual([
      { type: "text_delta", text: "see that " },
      { type: "text_delta", text: "button [POINT:1200,60:download pdf]" },
    ]);
    expect(events[5]).toEqual({
      type: "message_delta",
      delta: { stop_reason: "end_turn", stop_sequence: null },
      usage: { input_tokens: 900, input_tokens_details: { cached_tokens: 512 }, output_tokens: 70 },
    });
  });

  it("ends the message once when the stream closes with no [DONE] marker, with whatever usage it saw", async () => {
    const events = await translate(geminiChunk({ id: "c1", model: "m", choices: [{ delta: { content: "hi" } }] }), 4096);

    expect(events.map((streamEvent) => streamEvent.type)).toEqual(["message_start", "content_block_start", "content_block_delta", "content_block_stop", "message_delta", "message_stop"]);
    expect(events[4]).toMatchObject({ usage: {} });
  });

  it("reports a length finish as max_tokens", async () => {
    const events = await translate(geminiChunk({ choices: [{ delta: { content: "x" }, finish_reason: "length" }] }) + "data: [DONE]\n\n", 4096);

    expect(events.find((streamEvent) => streamEvent.type === "message_delta")).toMatchObject({ delta: { stop_reason: "max_tokens" } });
  });

  it("answers an error chunk with one error event and ignores what follows", async () => {
    const events = await translate(
      geminiChunk({ error: { code: 429, message: "quota exceeded" } }) + geminiChunk({ choices: [{ delta: { content: "late" } }] }) + "data: [DONE]\n\n",
      4096,
    );

    expect(events).toEqual([{ type: "error", error: { type: "api_error", message: "quota exceeded" } }]);
  });
});

describe("forwardChatToGemini", () => {
  const chatBody = {
    model: "claude-sonnet-5-5",
    max_tokens: 1024,
    stream: true,
    output_config: { effort: "low" },
    system: [{ type: "text", text: "you're clicky", cache_control: { type: "ephemeral" } }],
    messages: [{ role: "user", content: [{ type: "text", text: "hi" }] }],
  };

  it("streams the answer back as Anthropic events from a body sent with stream and include_usage on", async () => {
    const upstreamStream =
      'data: {"id":"c1","model":"gemini-4-neon","choices":[{"delta":{"content":"hello"}}]}\n\n' +
      'data: {"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}\n\n' +
      "data: [DONE]\n\n";
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => new Response(upstreamStream, { headers: { "content-type": "text/event-stream" } }));
    vi.stubGlobal("fetch", fetchMock);

    const response = await forwardChatToGemini(geminiOverride({ model: "gemini-4-neon" }), JSON.stringify(chatBody));

    expect(response.headers.get("content-type")).toBe("text/event-stream");
    const streamText = await response.text();
    expect(streamText).toContain('"text_delta","text":"hello"');
    expect(streamText).toContain('"output_tokens":2');
    expect(fetchMock.mock.calls[0]?.[0]).toBe(geminiChatCompletionsURL);
    expect(JSON.parse(String(fetchMock.mock.calls[0]?.[1].body))).toEqual({
      model: "gemini-4-neon",
      messages: [
        { role: "system", content: "you're clicky" },
        { role: "user", content: [{ type: "text", text: "hi" }] },
      ],
      max_tokens: 1024,
      reasoning_effort: "low",
      stream: true,
      stream_options: { include_usage: true },
    });
  });

  it("passes a Gemini error back with its status", async () => {
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.stubGlobal("fetch", vi.fn(async () => new Response('{"error":"rate limited"}', { status: 429 })));

    const response = await forwardChatToGemini(geminiOverride(), JSON.stringify(chatBody));

    expect(response.status).toBe(429);
    expect(await response.text()).toBe('{"error":"rate limited"}');
  });

  it("answers 400 for a body that is not JSON and 501 for one it cannot port, without calling Gemini", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    expect((await forwardChatToGemini(geminiOverride(), "not json")).status).toBe(400);
    expect((await forwardChatToGemini(geminiOverride(), JSON.stringify({ messages: [{ role: "assistant", content: [{ type: "tool_use", id: "t", name: "x", input: {} }] }] }))).status).toBe(501);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
