/**
 * The benchmark override seen from the routes: with no BENCH_MODEL every route sends what it sent before the
 * override existed, and with one each route's real request is ported to the other vendor.
 */

import { afterEach, describe, expect, it, vi } from "vitest";
import worker from "./index";
import { requestAnthropicMessage } from "./anthropic";
import { configureBenchModelOverride } from "./benchModelOverride";

const baseEnv = {
  ANTHROPIC_API_KEY: "anthropic-key",
  ELEVENLABS_API_KEY: "elevenlabs-key",
  ELEVENLABS_VOICE_ID: "voice-id",
  ASSEMBLYAI_API_KEY: "assemblyai-key",
  OPENAI_API_KEY: "openai-key",
};
const gptEnv = { ...baseEnv, BENCH_MODEL: "gpt-6-luna", BENCH_SERVICE_TIER: "ultrafast" };
const claudeEnv = { ...baseEnv, BENCH_MODEL: "claude-haiku-5-5", BENCH_EFFORT: "medium" };

afterEach(() => {
  configureBenchModelOverride({});
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

const anthropicURL = "https://api.anthropic.com/v1/messages";
const openAIURL = "https://api.openai.com/v1/responses";

/** One valid request per route that calls requestAnthropicMessage, as the app sends it. */
const routeRequests: Array<{ route: string; body: unknown; defaultModel: string }> = [
  {
    route: "/judge-answer",
    defaultModel: "claude-sonnet-5-5",
    body: { question: "What is this?", answerLabel: "left ventricle", explanation: "It pumps blood.", transcript: "the left ventricle" },
  },
  {
    route: "/video-quiz-plan",
    defaultModel: "claude-sonnet-5-5",
    body: { title: "Sharks", transcriptLines: [{ seconds: 0, text: "Sharks float." }, { seconds: 30, text: "Their liver holds oil." }] },
  },
  {
    route: "/video-frame-parts",
    defaultModel: "claude-sonnet-5-5",
    body: { frameBase64: "QUJD", frameWidth: 1280, frameHeight: 720, subject: "", question: "", answerLabel: "" },
  },
  {
    route: "/landmark",
    defaultModel: "claude-sonnet-5-5",
    body: { frameBase64: "QUJD", videoTitle: "A day in Paris", learnerRequest: "show me this in 3D" },
  },
  {
    route: "/picture-flows",
    defaultModel: "claude-opus-5-5",
    body: { frameBase64: "QUJD", frameWidth: 1280, frameHeight: 720, partLabels: ["Aorta"] },
  },
  {
    route: "/voice-command",
    defaultModel: "claude-haiku-5-5",
    body: {
      messages: [{ role: "user", content: 'Learner said: "turn it left"' }],
      tools: [
        {
          name: "rotate_model",
          description: "Orbit the camera.",
          inputSchema: { type: "object", properties: { yawDegrees: { type: "number" }, pitchDegrees: { type: "number" } }, required: ["yawDegrees"] },
        },
      ],
    },
  },
];

function post(route: string, body: unknown, env: Parameters<typeof worker.fetch>[1]): Promise<Response> {
  return worker.fetch(new Request(`http://127.0.0.1:8791${route}`, { method: "POST", body: JSON.stringify(body) }), env);
}

/** A reply every route can fail on, since these tests read the request and not the reply. */
const emptyAnthropicReply = () => new Response(JSON.stringify({ content: [{ type: "text", text: "{}" }], usage: {} }));
const emptyOpenAIReply = () => new Response(JSON.stringify({ model: "gpt-6-luna", output: [{ type: "message", content: [{ type: "output_text", text: "{}" }] }], usage: {} }));

function stubFetch(makeReply: () => Response) {
  const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => makeReply());
  vi.stubGlobal("fetch", fetchMock);
  vi.spyOn(console, "log").mockImplementation(() => undefined);
  vi.spyOn(console, "error").mockImplementation(() => undefined);
  return fetchMock;
}

const sentBody = (fetchMock: ReturnType<typeof stubFetch>) => JSON.parse(String(fetchMock.mock.calls[0]?.[1].body));

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** OpenAI's strict mode refuses an object schema that leaves out additionalProperties: false or does not require every property. */
function strictSchemaProblems(schema: unknown, path: string): string[] {
  if (!isRecord(schema)) {
    return [];
  }
  const problems: string[] = [];
  const properties = isRecord(schema.properties) ? schema.properties : {};
  if (schema.type === "object") {
    const required = Array.isArray(schema.required) ? schema.required : [];
    if (schema.additionalProperties !== false) {
      problems.push(`${path} has no additionalProperties: false`);
    }
    if (Object.keys(properties).some((propertyName) => !required.includes(propertyName))) {
      problems.push(`${path} does not require every property`);
    }
  }
  for (const [propertyName, propertySchema] of Object.entries(properties)) {
    problems.push(...strictSchemaProblems(propertySchema, `${path}.${propertyName}`));
  }
  problems.push(...strictSchemaProblems(schema.items, `${path}[]`));
  return problems;
}

describe("with no BENCH_MODEL", () => {
  it("sends the request helper's body to Anthropic as it did before the override existed", async () => {
    const fetchMock = stubFetch(emptyAnthropicReply);
    const requestBody = { model: "claude-sonnet-5-5", max_tokens: 5, system: "you're clicky", messages: [{ role: "user", content: "hi" }] };

    await requestAnthropicMessage("anthropic-key", "/test-route", requestBody);

    const [url, init] = fetchMock.mock.calls[0] ?? [];
    expect(url).toBe(anthropicURL);
    expect(init?.headers).toEqual({ "x-api-key": "anthropic-key", "anthropic-version": "2023-06-01", "content-type": "application/json" });
    expect(sentBody(fetchMock)).toEqual({ ...requestBody, system: [{ type: "text", text: "you're clicky", cache_control: { type: "ephemeral" } }] });
  });

  it.each(routeRequests)("keeps $route on $defaultModel and calls only Anthropic", async ({ route, body, defaultModel }) => {
    const fetchMock = stubFetch(emptyAnthropicReply);

    await post(route, body, baseEnv);

    expect(fetchMock.mock.calls.map((fetchCall) => fetchCall[0])).toEqual(expect.arrayContaining([anthropicURL]));
    expect(fetchMock.mock.calls.every((fetchCall) => fetchCall[0] === anthropicURL)).toBe(true);
    expect(sentBody(fetchMock).model).toBe(defaultModel);
  });

  it("ignores BENCH_EFFORT and BENCH_SERVICE_TIER, which only mean something next to a BENCH_MODEL", async () => {
    const fetchMock = stubFetch(emptyAnthropicReply);
    const [judgeRoute] = routeRequests;

    await post(judgeRoute.route, judgeRoute.body, { ...baseEnv, BENCH_EFFORT: "max", BENCH_SERVICE_TIER: "ultrafast" });

    expect(sentBody(fetchMock).model).toBe("claude-sonnet-5-5");
    expect(sentBody(fetchMock).output_config.effort).toBe("low");
  });

  it("forgets the override of the request before it", async () => {
    const fetchMock = stubFetch(emptyOpenAIReply);
    const [judgeRoute] = routeRequests;

    await post(judgeRoute.route, judgeRoute.body, gptEnv);
    await post(judgeRoute.route, judgeRoute.body, baseEnv);

    expect(fetchMock.mock.calls.map((fetchCall) => fetchCall[0])).toEqual([openAIURL, anthropicURL]);
  });

  it("sends a /chat body to Anthropic byte for byte", async () => {
    const fetchMock = stubFetch(emptyAnthropicReply);
    const chatBodyText = JSON.stringify({ model: "claude-sonnet-5-5", stream: true, system: "you're clicky", messages: [] });

    await worker.fetch(new Request("http://127.0.0.1:8791/chat", { method: "POST", body: chatBodyText }), baseEnv);

    expect(fetchMock.mock.calls[0]?.[0]).toBe(anthropicURL);
    expect(fetchMock.mock.calls[0]?.[1].body).toBe(chatBodyText);
  });
});

describe("with a bad BENCH_MODEL", () => {
  it("answers 500 with the problem before any model call", async () => {
    const fetchMock = stubFetch(emptyAnthropicReply);
    const [judgeRoute] = routeRequests;

    const response = await post(judgeRoute.route, judgeRoute.body, { ...baseEnv, BENCH_MODEL: "llama-4" });

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: "BENCH_MODEL must start with claude-, gpt-, or gemini-, not llama-4" });
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe("with a Claude BENCH_MODEL", () => {
  it.each(routeRequests)("sends $route to Anthropic on the override's model and effort", async ({ route, body }) => {
    const fetchMock = stubFetch(emptyAnthropicReply);

    await post(route, body, claudeEnv);

    expect(fetchMock.mock.calls.every((fetchCall) => fetchCall[0] === anthropicURL)).toBe(true);
    expect(sentBody(fetchMock).model).toBe("claude-haiku-5-5");
    expect(sentBody(fetchMock).output_config.effort).toBe("medium");
  });

  it("changes the model of a /chat body and nothing else", async () => {
    const fetchMock = stubFetch(emptyAnthropicReply);
    const chatBody = { model: "claude-sonnet-5-5", stream: true, system: "you're clicky", messages: [] };

    await worker.fetch(new Request("http://127.0.0.1:8791/chat", { method: "POST", body: JSON.stringify(chatBody) }), { ...baseEnv, BENCH_MODEL: "claude-haiku-5-5" });

    expect(sentBody(fetchMock)).toEqual({ ...chatBody, model: "claude-haiku-5-5" });
  });

  it("never changes /v1/messages, which serves the agent harness", async () => {
    const fetchMock = stubFetch(emptyAnthropicReply);
    const messagesBodyText = JSON.stringify({ model: "claude-sonnet-5-5", messages: [] });

    await worker.fetch(
      new Request("http://127.0.0.1:8791/v1/messages", { method: "POST", body: messagesBodyText, headers: { "x-clicky-app-secret": "app-secret" } }),
      { ...claudeEnv, CLICKY_APP_SECRET: "app-secret" },
    );

    expect(fetchMock.mock.calls[0]?.[1].body).toBe(messagesBodyText);
  });
});

describe("with a GPT BENCH_MODEL", () => {
  it.each(routeRequests)("sends $route to OpenAI, with the tier, and never to Anthropic", async ({ route, body }) => {
    const fetchMock = stubFetch(emptyOpenAIReply);

    await post(route, body, gptEnv);

    const [url, init] = fetchMock.mock.calls[0] ?? [];
    expect(url).toBe(openAIURL);
    expect(init?.headers).toEqual({ authorization: "Bearer openai-key", "content-type": "application/json" });
    expect(fetchMock.mock.calls.every((fetchCall) => fetchCall[0] === openAIURL)).toBe(true);
    expect(sentBody(fetchMock)).toMatchObject({ model: "gpt-6-luna", service_tier: "ultrafast" });
  });

  it.each(routeRequests.filter(({ route }) => route !== "/voice-command"))(
    "gives $route's real schema to strict mode, which needs every property required",
    async ({ route, body }) => {
      const fetchMock = stubFetch(emptyOpenAIReply);

      await post(route, body, gptEnv);

      const { format } = sentBody(fetchMock).text;
      expect(format).toMatchObject({ type: "json_schema", strict: true });
      expect(strictSchemaProblems(format.schema, "schema")).toEqual([]);
    },
  );

  it("sends /video-frame-parts' frame as an image the model can read", async () => {
    const fetchMock = stubFetch(emptyOpenAIReply);
    const frameRoute = routeRequests.find(({ route }) => route === "/video-frame-parts");

    await post("/video-frame-parts", frameRoute?.body, gptEnv);

    expect(sentBody(fetchMock).input[0].content[0]).toEqual({ type: "input_image", image_url: "data:image/jpeg;base64,QUJD", detail: "high" });
  });

  it("answers /judge-answer from a Responses reply, and logs the usage with the tier for the benchmark", async () => {
    const usage = { input_tokens: 300, input_tokens_details: { cached_tokens: 0 }, output_tokens: 20 };
    stubFetch(
      () =>
        new Response(
          JSON.stringify({
            model: "gpt-6-luna-2026-11-12",
            service_tier: "ultrafast",
            output: [{ type: "message", content: [{ type: "output_text", text: '{"verdict":"correct","spokenReply":"Yes, it pumps blood."}' }] }],
            usage,
          }),
        ),
    );
    const [judgeRoute] = routeRequests;

    const response = await post(judgeRoute.route, judgeRoute.body, gptEnv);

    expect(await response.json()).toEqual({ verdict: "correct", spokenReply: "Yes, it pumps blood." });
    expect(console.log).toHaveBeenCalledWith(`[/judge-answer] usage ${JSON.stringify({ model: "gpt-6-luna-2026-11-12", ...usage, service_tier: "ultrafast" })}`);
  });

  it("answers /voice-command with the function call as a tool_use block", async () => {
    stubFetch(
      () =>
        new Response(
          JSON.stringify({
            model: "gpt-6-luna",
            output: [{ type: "function_call", call_id: "call_1", name: "rotate_model", arguments: '{"yawDegrees":-45,"confirmation":"turned it left"}' }],
            usage: {},
          }),
        ),
    );
    const voiceRoute = routeRequests.find(({ route }) => route === "/voice-command");

    const response = await post("/voice-command", voiceRoute?.body, gptEnv);

    expect(await response.json()).toEqual({
      content: [{ type: "tool_use", id: "call_1", name: "rotate_model", input: { yawDegrees: -45, confirmation: "turned it left" } }],
      stopReason: "tool_use",
    });
  });

  it("sends the voice tools as non-strict functions, since their schemas have optional properties", async () => {
    const fetchMock = stubFetch(emptyOpenAIReply);
    const voiceRoute = routeRequests.find(({ route }) => route === "/voice-command");

    await post("/voice-command", voiceRoute?.body, gptEnv);

    const { tools, reasoning } = sentBody(fetchMock);
    expect(tools[0]).toMatchObject({ type: "function", name: "rotate_model", strict: false });
    // /voice-command turns thinking off on Haiku, so GPT gets the lowest effort it accepts.
    expect(reasoning).toEqual({ effort: "none" });
  });

  it("streams /chat back as Anthropic events, and sends the app's own request to OpenAI with stream on", async () => {
    const fetchMock = stubFetch(
      () => new Response('data: {"type":"response.output_text.delta","delta":"hi"}\n\ndata: {"type":"response.completed","response":{"usage":{"output_tokens":1}}}\n\n'),
    );
    const chatBody = { model: "claude-sonnet-5-5", max_tokens: 1024, stream: true, system: "you're clicky", messages: [{ role: "user", content: "hi" }] };

    const response = await worker.fetch(new Request("http://127.0.0.1:8791/chat", { method: "POST", body: JSON.stringify(chatBody) }), gptEnv);

    expect(await response.text()).toContain('"text_delta","text":"hi"');
    expect(fetchMock.mock.calls[0]?.[0]).toBe(openAIURL);
    expect(sentBody(fetchMock)).toMatchObject({ model: "gpt-6-luna", stream: true, instructions: "you're clicky", max_output_tokens: 1024 });
  });

  it("never changes /v1/messages, which serves the agent harness", async () => {
    const fetchMock = stubFetch(emptyAnthropicReply);
    const messagesBodyText = JSON.stringify({ model: "claude-sonnet-5-5", messages: [] });

    await worker.fetch(
      new Request("http://127.0.0.1:8791/v1/messages", { method: "POST", body: messagesBodyText, headers: { "x-clicky-app-secret": "app-secret" } }),
      { ...gptEnv, CLICKY_APP_SECRET: "app-secret" },
    );

    expect(fetchMock.mock.calls[0]?.[0]).toBe(anthropicURL);
    expect(fetchMock.mock.calls[0]?.[1].body).toBe(messagesBodyText);
  });
});
