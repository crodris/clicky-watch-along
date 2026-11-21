import { afterEach, describe, expect, it, vi } from "vitest";
import { configureBenchModelOverride } from "./benchModelOverride";
import { handleJudgeAnswer, handleLiveScene } from "./liveScene";

const judgeRequest = {
  question: "Let's pause here! What opens and closes like parachutes inside the ventricle?",
  answerLabel: "Valves",
  explanation: "The valves open and close so blood only flows one way.",
  transcript: "the vowels",
};

function requestWithBody(body: unknown): Request {
  return new Request("https://worker.test/judge-answer", { method: "POST", body: JSON.stringify(body) });
}

function verdictReply(text: string): Response {
  return new Response(JSON.stringify({ content: [{ type: "thinking", thinking: "" }, { type: "text", text }] }));
}

afterEach(() => {
  configureBenchModelOverride({});
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("handleJudgeAnswer", () => {
  it("asks Sonnet for the verdict as JSON and returns it", async () => {
    const verdict = { verdict: "named_only", spokenReply: "Yes, those are the valves, so what do they do?" };
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => verdictReply(JSON.stringify(verdict)));
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleJudgeAnswer(requestWithBody(judgeRequest), "key");

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(verdict);
    const sentBody: unknown = JSON.parse(String(fetchMock.mock.calls[0]?.[1].body));
    expect(sentBody).toMatchObject({
      model: "claude-sonnet-5-5",
      output_config: { effort: "low", format: { type: "json_schema" } },
    });
    expect(sentBody).not.toHaveProperty("tool_choice");
  });

  it("logs the token usage the reply reports", async () => {
    const consoleLogSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const verdict = { verdict: "correct", spokenReply: "Yes, the valves keep blood flowing one way." };
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(
          JSON.stringify({ content: [{ type: "text", text: JSON.stringify(verdict) }], usage: { input_tokens: 812, output_tokens: 64 } }),
        ),
      ),
    );

    await handleJudgeAnswer(requestWithBody(judgeRequest), "key");

    expect(consoleLogSpy).toHaveBeenCalledWith('[/judge-answer] usage {"input_tokens":812,"output_tokens":64}');
  });

  it.each(["skip_question", "repeat_question", "scene_command"])(
    "returns %s with an empty spoken reply, because the app speaks its own line",
    async (verdict) => {
      vi.stubGlobal("fetch", vi.fn(async () => verdictReply(JSON.stringify({ verdict, spokenReply: "" }))));

      const response = await handleJudgeAnswer(requestWithBody({ ...judgeRequest, transcript: "turn it left" }), "key");

      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ verdict, spokenReply: "" });
    },
  );

  it("returns a hint verdict with its hint sentence", async () => {
    const verdict = { verdict: "wants_hint", spokenReply: "Think about what stops blood from flowing backward." };
    vi.stubGlobal("fetch", vi.fn(async () => verdictReply(JSON.stringify(verdict))));

    const response = await handleJudgeAnswer(requestWithBody({ ...judgeRequest, transcript: "give me a hint" }), "key");

    expect(await response.json()).toEqual(verdict);
  });

  it.each(["correct", "named_only", "wrong", "asked_for_help", "wants_hint"])(
    "returns 502 when a %s verdict has no spoken reply",
    async (verdict) => {
      vi.stubGlobal("fetch", vi.fn(async () => verdictReply(JSON.stringify({ verdict, spokenReply: "" }))));

      const response = await handleJudgeAnswer(requestWithBody(judgeRequest), "key");

      expect(response.status).toBe(502);
    },
  );

  it("lists every verdict in the reply schema and the prompt", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) =>
      verdictReply(JSON.stringify({ verdict: "wrong", spokenReply: "Not quite." })),
    );
    vi.stubGlobal("fetch", fetchMock);

    await handleJudgeAnswer(requestWithBody(judgeRequest), "key");

    const sentBody = JSON.parse(String(fetchMock.mock.calls[0]?.[1].body));
    const verdictsInSchema = sentBody.output_config.format.schema.properties.verdict.enum;
    expect(verdictsInSchema).toEqual([
      "correct",
      "named_only",
      "wrong",
      "asked_for_help",
      "skip_question",
      "repeat_question",
      "wants_hint",
      "scene_command",
    ]);
    for (const verdict of verdictsInSchema) {
      expect(sentBody.system[0].text).toContain(`"${verdict}"`);
    }
  });

  it("returns 502 when the reply text is not a verdict", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => verdictReply("Sure! They named the valves.")));

    const response = await handleJudgeAnswer(requestWithBody(judgeRequest), "key");

    expect(response.status).toBe(502);
  });
});

const sceneRequest = { question: "show me a heart in 3D", screenshotBase64: "AAAA", screenshotMediaType: "image/jpeg" };

const scenePage = `<!DOCTYPE html><html><body>
<script type="importmap">{ "imports": { "three": "clicky-asset://three/three.module.js" } }</script>
<script type="module">
window.liveScene = { reveal() {}, zoomBy(amount) {}, focusPart(labelText) { return false; } };
window.webkit?.messageHandlers?.liveSceneEvent?.postMessage("tourFinished");
</script></body></html>`;

const sceneQuiz = { question: "What is this?", answerLabel: "Valve", functionWords: ["flow"], explanation: "It keeps blood moving one way." };

const sceneModelReply = "```html\n" + scenePage + "\n```\n```json\n" + JSON.stringify(sceneQuiz) + "\n```";

const simulationPage = scenePage.replace(
  "reveal() {},",
  `reveal() {},
  controls: [{ name: "angle", label: "Launch angle", min: 5, max: 85, step: 1, value: 45, unit: "degrees" }],
  setControl(name, value) { return name === "angle"; },
  run() { return Promise.resolve(); },
  getState() { return { readouts: [] }; },`,
);

const simulationModelReply =
  "```html\n" + simulationPage + "\n```\n```json\n" + JSON.stringify({ ...sceneQuiz, functionWords: [] }) + "\n```";

const sceneKeys = { OPENAI_API_KEY: "openai-key", ANTHROPIC_API_KEY: "anthropic-key" };

describe("handleLiveScene with a benchmark BENCH_MODEL", () => {
  it("runs a gpt-* model on the GPT request, at the standard tier unless BENCH_SERVICE_TIER names one", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => new Response(JSON.stringify({ output_text: sceneModelReply })));
    vi.stubGlobal("fetch", fetchMock);
    vi.spyOn(console, "log").mockImplementation(() => {});

    configureBenchModelOverride({ BENCH_MODEL: "gpt-6.2-astra", BENCH_EFFORT: "minimal", OPENAI_API_KEY: "openai-key" });
    await handleLiveScene(requestWithBody(sceneRequest), sceneKeys);
    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://api.openai.com/v1/responses");
    const standardTierBody: unknown = JSON.parse(String(fetchMock.mock.calls[0]?.[1].body));
    expect(standardTierBody).toMatchObject({ model: "gpt-6.2-astra", reasoning: { effort: "minimal" }, instructions: expect.any(String) });
    expect(standardTierBody).not.toHaveProperty("service_tier");

    configureBenchModelOverride({ BENCH_MODEL: "gpt-6.1-sol", BENCH_SERVICE_TIER: "ultrafast", OPENAI_API_KEY: "openai-key" });
    await handleLiveScene(requestWithBody(sceneRequest), { ...sceneKeys, LIVE_SCENE_MODEL: "sonnet" });
    expect(JSON.parse(String(fetchMock.mock.calls[1]?.[1].body))).toMatchObject({ model: "gpt-6.1-sol", service_tier: "ultrafast", reasoning: { effort: "medium" } });
  });

  it("runs any other model on the Claude request at the Claude scene effort, whatever LIVE_SCENE_MODEL says", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => verdictReply(sceneModelReply));
    vi.stubGlobal("fetch", fetchMock);
    vi.spyOn(console, "log").mockImplementation(() => {});
    configureBenchModelOverride({ BENCH_MODEL: "claude-haiku-5-5" });

    const response = await handleLiveScene(requestWithBody(sceneRequest), sceneKeys);

    expect(response.status).toBe(200);
    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://api.anthropic.com/v1/messages");
    expect(JSON.parse(String(fetchMock.mock.calls[0]?.[1].body))).toMatchObject({ model: "claude-haiku-5-5", output_config: { effort: "low" } });
  });
});

describe("handleLiveScene when OpenAI cannot answer", () => {
  // Answers OpenAI with the given failure and Anthropic with the given reply, and records every call by vendor.
  function stubOpenAIAndAnthropic(openAIAnswer: () => Response, anthropicReplyText: string) {
    const fetchMock = vi.fn(async (url: string, _init: RequestInit) =>
      url.startsWith("https://api.openai.com") ? openAIAnswer() : verdictReply(anthropicReplyText),
    );
    vi.stubGlobal("fetch", fetchMock);
    return {
      fetchMock,
      openAICalls: () => fetchMock.mock.calls.filter((call) => call[0].startsWith("https://api.openai.com")),
      anthropicCalls: () => fetchMock.mock.calls.filter((call) => call[0].startsWith("https://api.anthropic.com")),
    };
  }

  function silenceConsole() {
    vi.spyOn(console, "log").mockImplementation(() => {});
    return vi.spyOn(console, "error").mockImplementation(() => {});
  }

  it.each([401, 403, 404, 429, 503])("builds the scene on Sonnet at its default effort when OpenAI answers %i", async (openAIStatus) => {
    const consoleErrorSpy = silenceConsole();
    const { anthropicCalls } = stubOpenAIAndAnthropic(() => new Response("nope", { status: openAIStatus }), sceneModelReply);

    // LIVE_SCENE_EFFORT=high is a GPT effort here, so the fallback must ignore it.
    const response = await handleLiveScene(requestWithBody(sceneRequest), { ...sceneKeys, LIVE_SCENE_EFFORT: "high" });

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ quiz: { answerLabel: "Valve" } });
    expect(anthropicCalls()).toHaveLength(1);
    expect(JSON.parse(String(anthropicCalls()[0]?.[1].body))).toMatchObject({ model: "claude-sonnet-5-5", output_config: { effort: "low" } });
    expect(consoleErrorSpy).toHaveBeenCalledWith(
      `[/live-scene] gpt-6.1-sol could not answer (HTTP ${openAIStatus}), so the scene falls back to claude-sonnet-5-5`,
    );
  });

  it("builds the scene on Sonnet when the fetch to OpenAI throws", async () => {
    silenceConsole();
    const fetchMock = vi.fn(async (url: string, _init: RequestInit) => {
      if (url.startsWith("https://api.openai.com")) {
        throw new TypeError("fetch failed");
      }
      return verdictReply(sceneModelReply);
    });
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleLiveScene(requestWithBody(sceneRequest), sceneKeys);

    expect(response.status).toBe(200);
    expect(JSON.parse(String(fetchMock.mock.calls[1]?.[1].body))).toMatchObject({ model: "claude-sonnet-5-5" });
  });

  it("returns OpenAI's 400 and never calls Anthropic, since a 400 is about the request", async () => {
    silenceConsole();
    const { anthropicCalls } = stubOpenAIAndAnthropic(() => new Response("bad request", { status: 400 }), sceneModelReply);

    const response = await handleLiveScene(requestWithBody(sceneRequest), sceneKeys);

    expect(response.status).toBe(400);
    expect(anthropicCalls()).toHaveLength(0);
  });

  it("checks the Sonnet page like any other, and retries on Sonnet, never on OpenAI, before a 422", async () => {
    silenceConsole();
    const simulationPageWithoutSetControl = simulationModelReply.replace("setControl(name, value)", "adjustControl(name, value)");
    const { openAICalls, anthropicCalls } = stubOpenAIAndAnthropic(() => new Response("rate limited", { status: 429 }), simulationPageWithoutSetControl);

    // LIVE_SCENE_EFFORT=high is a GPT effort here, so neither Sonnet attempt may take it.
    const response = await handleLiveScene(requestWithBody({ ...sceneRequest, kind: "simulation" }), { ...sceneKeys, LIVE_SCENE_EFFORT: "high" });

    expect(response.status).toBe(422);
    expect(await response.json()).toEqual({ error: "The simulation page is missing setControl" });
    expect(openAICalls()).toHaveLength(1);
    expect(anthropicCalls()).toHaveLength(2);
    for (const anthropicCall of anthropicCalls()) {
      expect(JSON.parse(String(anthropicCall[1].body))).toMatchObject({ model: "claude-sonnet-5-5", output_config: { effort: "low" } });
    }
  });

  it("never falls back under a gpt-* BENCH_MODEL, which measures one model", async () => {
    silenceConsole();
    configureBenchModelOverride({ BENCH_MODEL: "gpt-6.2-astra", OPENAI_API_KEY: "openai-key" });
    const { fetchMock } = stubOpenAIAndAnthropic(() => new Response("rate limited", { status: 429 }), sceneModelReply);

    const response = await handleLiveScene(requestWithBody(sceneRequest), sceneKeys);

    // A gpt-* override sends every request to OpenAI, so a fallback shows as a second call, not as an Anthropic one.
    expect(response.status).toBe(429);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
});

describe("handleLiveScene model setting", () => {
  it("asks GPT when LIVE_SCENE_MODEL is not set and logs its token usage", async () => {
    const consoleLogSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const fetchMock = vi.fn(
      async (_url: string, _init: RequestInit) =>
        new Response(JSON.stringify({ output_text: sceneModelReply, usage: { input_tokens: 2400, output_tokens: 4100 } })),
    );
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleLiveScene(requestWithBody(sceneRequest), sceneKeys);

    expect(response.status).toBe(200);
    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://api.openai.com/v1/responses");
    expect(consoleLogSpy).toHaveBeenCalledWith('[/live-scene] usage {"input_tokens":2400,"output_tokens":4100}');
  });

  it("tells a simulation's model to name its animation callbacks and never declare frame twice", async () => {
    // GPT-6.2 Sol declared `frame` twice in about a third of simulation pages on 2026-11-19, which the page check
    // rejects, and a rejected retry fails the whole build.
    const fetchMock = vi.fn(
      async (_url: string, _init: RequestInit) => new Response(JSON.stringify({ output_text: sceneModelReply, usage: {} })),
    );
    vi.stubGlobal("fetch", fetchMock);
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});

    await handleLiveScene(requestWithBody({ ...sceneRequest, kind: "simulation" }), sceneKeys);

    const sentBody = JSON.parse(String(fetchMock.mock.calls[0]?.[1].body)) as { instructions: string };
    expect(sentBody.instructions).toContain("such as stepRun or stepTour, never frame, and declare each name only once in its scope");
  });

  it("asks Sonnet when LIVE_SCENE_MODEL is sonnet and returns its page", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => verdictReply(sceneModelReply));
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleLiveScene(requestWithBody(sceneRequest), { ...sceneKeys, LIVE_SCENE_MODEL: "sonnet" });

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ quiz: { answerLabel: "Valve" } });
    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://api.anthropic.com/v1/messages");
    const sentBody: unknown = JSON.parse(String(fetchMock.mock.calls[0]?.[1].body));
    expect(sentBody).toMatchObject({ model: "claude-sonnet-5-5" });
  });

  it("asks Claude Fable 5.2 when LIVE_SCENE_MODEL is fable", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => verdictReply(sceneModelReply));
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleLiveScene(requestWithBody(sceneRequest), { ...sceneKeys, LIVE_SCENE_MODEL: "fable" });

    expect(response.status).toBe(200);
    const sentBody: unknown = JSON.parse(String(fetchMock.mock.calls[0]?.[1].body));
    expect(sentBody).toMatchObject({ model: "claude-fable-5-2" });
  });

  it("asks GPT at medium reasoning effort and Sonnet at low effort when LIVE_SCENE_EFFORT is not set", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => verdictReply(sceneModelReply));
    vi.stubGlobal("fetch", fetchMock);

    await handleLiveScene(requestWithBody(sceneRequest), sceneKeys);
    expect(JSON.parse(String(fetchMock.mock.calls[0]?.[1].body))).toMatchObject({ reasoning: { effort: "medium" } });

    fetchMock.mockClear();
    await handleLiveScene(requestWithBody(sceneRequest), { ...sceneKeys, LIVE_SCENE_MODEL: "sonnet" });
    expect(JSON.parse(String(fetchMock.mock.calls[0]?.[1].body))).toMatchObject({ output_config: { effort: "low" } });
  });

  it("sends LIVE_SCENE_EFFORT to GPT as its reasoning effort", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => verdictReply(sceneModelReply));
    vi.stubGlobal("fetch", fetchMock);

    await handleLiveScene(requestWithBody(sceneRequest), { ...sceneKeys, LIVE_SCENE_EFFORT: "medium" });

    const sentBody: unknown = JSON.parse(String(fetchMock.mock.calls[0]?.[1].body));
    expect(sentBody).toMatchObject({ model: "gpt-6.1-sol", reasoning: { effort: "medium" } });
  });

  it("sends LIVE_SCENE_EFFORT to a Claude scene model", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => verdictReply(sceneModelReply));
    vi.stubGlobal("fetch", fetchMock);

    await handleLiveScene(requestWithBody(sceneRequest), { ...sceneKeys, LIVE_SCENE_MODEL: "opus", LIVE_SCENE_EFFORT: "high" });

    const sentBody: unknown = JSON.parse(String(fetchMock.mock.calls[0]?.[1].body));
    expect(sentBody).toMatchObject({ model: "claude-opus-5-5", output_config: { effort: "high" } });
  });

  it("tells the model about the camera and part tools the app drives after the tour", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => verdictReply(sceneModelReply));
    vi.stubGlobal("fetch", fetchMock);

    await handleLiveScene(requestWithBody(sceneRequest), { ...sceneKeys, LIVE_SCENE_MODEL: "sonnet" });

    const sentBody = JSON.parse(String(fetchMock.mock.calls[0]?.[1].body));
    const systemText: string = sentBody.system[0].text;
    for (const marker of ["rotateBy(", "endTour()", "getState()", "isOuterShell", "renderer.localClippingEnabled = true"]) {
      expect(systemText).toContain(marker);
    }
  });

  it("builds a simulation on GPT-6.2 Sol and a 3D model, or an older app's request, on GPT-6.1 Sol, both at Ultrafast", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => new Response(JSON.stringify({ output_text: simulationModelReply })));
    vi.stubGlobal("fetch", fetchMock);
    vi.spyOn(console, "log").mockImplementation(() => {});

    await handleLiveScene(requestWithBody({ ...sceneRequest, kind: "simulation" }), sceneKeys);
    await handleLiveScene(requestWithBody({ ...sceneRequest, kind: "model" }), sceneKeys);
    await handleLiveScene(requestWithBody(sceneRequest), sceneKeys);

    const sentModels = fetchMock.mock.calls.map((call) => {
      const sentBody = JSON.parse(String(call[1].body));
      return `${sentBody.model} ${sentBody.service_tier}`;
    });
    expect(sentModels).toEqual(["gpt-6.2-sol ultrafast", "gpt-6.1-sol ultrafast", "gpt-6.1-sol ultrafast"]);
  });

  it("sends the simulation rules only when the request kind is simulation", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => verdictReply(simulationModelReply));
    vi.stubGlobal("fetch", fetchMock);
    const sonnetKeys = { ...sceneKeys, LIVE_SCENE_MODEL: "sonnet" };

    await handleLiveScene(requestWithBody({ ...sceneRequest, kind: "simulation" }), sonnetKeys);
    await handleLiveScene(requestWithBody({ ...sceneRequest, kind: "model" }), sonnetKeys);
    await handleLiveScene(requestWithBody(sceneRequest), sonnetKeys);

    const systemTexts = fetchMock.mock.calls.map((call) => JSON.parse(String(call[1].body)).system[0].text as string);
    expect(systemTexts[0]).toContain("THIS REQUEST IS A SIMULATION");
    expect(systemTexts[0]).toContain("setControl(name, value)");
    // The dashed path preview and the hidden labels are part of what a simulation is asked for.
    expect(systemTexts[0]).toContain("dashed line");
    expect(systemTexts[0]).toContain("setLabelsVisible(visible)");
    expect(systemTexts[0]).toContain("hidden at first");
    expect(systemTexts[0]).toContain("setPreviewVisible(visible)");
    expect(systemTexts[0]).toContain("setChallengeVisible(visible)");
    expect(systemTexts[0]).toContain("the marker and the whole path to it are in view");
    // A screen that is not a science lesson still gets a science experiment, never a copy of the app.
    expect(systemTexts[0]).toContain("build the science experiment behind what it shows");
    expect(systemTexts[0]).toContain("Newton's law of cooling");
    expect(systemTexts[0]).toContain("a grassy field for one that covers many meters");
    expect(systemTexts[0]).toContain("keep the path it took as a thin, solid, faded line");
    expect(systemTexts[1]).not.toContain("SIMULATION");
    expect(systemTexts[2]).toBe(systemTexts[1]);
  });

  it("returns a simulation page that has its controls, and retries once before a 422 when it has none", async () => {
    const goodFetch = vi.fn(async (_url: string, _init: RequestInit) => verdictReply(simulationModelReply));
    vi.stubGlobal("fetch", goodFetch);
    const goodResponse = await handleLiveScene(requestWithBody({ ...sceneRequest, kind: "simulation" }), { ...sceneKeys, LIVE_SCENE_MODEL: "sonnet" });
    expect(goodResponse.status).toBe(200);
    expect(goodFetch).toHaveBeenCalledTimes(1);

    vi.spyOn(console, "error").mockImplementation(() => {});
    const modelPageFetch = vi.fn(async (_url: string, _init: RequestInit) => verdictReply(sceneModelReply));
    vi.stubGlobal("fetch", modelPageFetch);
    const badResponse = await handleLiveScene(requestWithBody({ ...sceneRequest, kind: "simulation" }), { ...sceneKeys, LIVE_SCENE_MODEL: "sonnet" });
    expect(badResponse.status).toBe(422);
    expect(await badResponse.json()).toEqual({ error: "The simulation page is missing controls" });
    expect(modelPageFetch).toHaveBeenCalledTimes(2);
  });

  it("refuses a request kind it does not know", async () => {
    const fetchMock = vi.fn(async () => new Response("{}"));
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleLiveScene(requestWithBody({ ...sceneRequest, kind: "quiz" }), { ...sceneKeys, LIVE_SCENE_MODEL: "sonnet" });

    expect(response.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("asks for only build(kit) under LIVE_SCENE_FORMAT kernel and returns the page that runs it in the bundled kernel", async () => {
    const buildCode = 'function build(kit) {\n  kit.part("Valve", new kit.THREE.Group());\n  return { insideView: false };\n}';
    const kernelReply = "```js\n" + buildCode + "\n```\n```json\n" + JSON.stringify(sceneQuiz) + "\n```";
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => new Response(JSON.stringify({ output_text: kernelReply, usage: {} })));
    vi.stubGlobal("fetch", fetchMock);
    vi.spyOn(console, "log").mockImplementation(() => {});

    const response = await handleLiveScene(requestWithBody(sceneRequest), { ...sceneKeys, LIVE_SCENE_FORMAT: "kernel" });

    expect(response.status).toBe(200);
    const reply = (await response.json()) as { html: string; quiz: unknown };
    expect(reply.quiz).toEqual(sceneQuiz);
    expect(reply.html).toContain('import { startScene } from "clicky-asset://three/scene-kernel.js";');
    expect(reply.html).toContain(buildCode);
    const instructions = JSON.parse(String(fetchMock.mock.calls[0]?.[1].body)).instructions as string;
    expect(instructions).toContain("Reply with a ```js block and then a ```json block.");
    expect(instructions).toContain("kit.part(label, object, { outerShell, anchor })");
    expect(instructions).not.toContain("window.liveScene.focusPart");
  });

  it("sends the kernel's simulation rules for a simulation under LIVE_SCENE_FORMAT kernel", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => new Response(JSON.stringify({ output_text: "no blocks", usage: {} })));
    vi.stubGlobal("fetch", fetchMock);
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});

    await handleLiveScene(requestWithBody({ ...sceneRequest, kind: "simulation" }), { ...sceneKeys, LIVE_SCENE_FORMAT: "kernel" });

    const instructions = JSON.parse(String(fetchMock.mock.calls[0]?.[1].body)).instructions as string;
    expect(instructions).toContain("THIS REQUEST IS A SIMULATION");
    expect(instructions).toContain("build returns { controls, setup, simulate, challenge, view }");
    expect(instructions).toContain("Newton's law of cooling");
    expect(instructions).toContain("build the science experiment behind what it shows");
    expect(instructions).not.toContain("setControl(name, value)");
  });

  it("refuses an unknown LIVE_SCENE_FORMAT without calling a model", async () => {
    const fetchMock = vi.fn(async () => new Response("{}"));
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleLiveScene(requestWithBody(sceneRequest), { ...sceneKeys, LIVE_SCENE_FORMAT: "recipe" });

    expect(response.status).toBe(500);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("refuses an unknown LIVE_SCENE_MODEL without calling a model", async () => {
    const fetchMock = vi.fn(async () => new Response("{}"));
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleLiveScene(requestWithBody(sceneRequest), { ...sceneKeys, LIVE_SCENE_MODEL: "haiku" });

    expect(response.status).toBe(500);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
