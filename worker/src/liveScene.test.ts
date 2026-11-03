import { afterEach, describe, expect, it, vi } from "vitest";
import { handleJudgeAnswer } from "./liveScene";

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
      output_config: { format: { type: "json_schema" } },
    });
    expect(sentBody).not.toHaveProperty("tool_choice");
  });

  it("returns 502 when the reply text is not a verdict", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => verdictReply("Sure! They named the valves.")));

    const response = await handleJudgeAnswer(requestWithBody(judgeRequest), "key");

    expect(response.status).toBe(502);
  });
});
