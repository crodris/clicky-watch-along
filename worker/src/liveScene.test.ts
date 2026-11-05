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
    consoleLogSpy.mockRestore();
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
    consoleLogSpy.mockRestore();
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

  it("refuses an unknown LIVE_SCENE_MODEL without calling a model", async () => {
    const fetchMock = vi.fn(async () => new Response("{}"));
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleLiveScene(requestWithBody(sceneRequest), { ...sceneKeys, LIVE_SCENE_MODEL: "opus" });

    expect(response.status).toBe(500);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
