import { afterEach, describe, expect, it, vi } from "vitest";
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

  it("refuses an unknown LIVE_SCENE_MODEL without calling a model", async () => {
    const fetchMock = vi.fn(async () => new Response("{}"));
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleLiveScene(requestWithBody(sceneRequest), { ...sceneKeys, LIVE_SCENE_MODEL: "haiku" });

    expect(response.status).toBe(500);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
