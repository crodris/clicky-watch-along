import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { judgeModels, judgeRequest, parseDevVars, requestJudgeVerdict } from "./judgeModels.ts";
import type { JudgePromptPart } from "./judgeRender.ts";
import { costOfUsageLine } from "./usage.ts";

const keys = { anthropicAPIKey: "anthropic-key", openAIAPIKey: "openai-key" };
const parts: JudgePromptPart[] = [
  { kind: "text", text: "criteria" },
  { kind: "image", base64: "QQ==", mediaType: "image/png" },
];

/** A fetch that answers with each response in turn, and records what it was sent. */
function fakeFetch(...responses: Response[]) {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const fetchImpl: typeof fetch = async (input, init) => {
    calls.push({ url: String(input), init: init ?? {} });
    return responses.shift() ?? new Response("{}", { status: 500 });
  };
  return { fetchImpl, calls };
}

const anthropicReply = (verdictText: string) =>
  new Response(JSON.stringify({ model: "claude-opus-5-5", content: [{ type: "thinking", thinking: "..." }, { type: "text", text: verdictText }], usage: { input_tokens: 2000, output_tokens: 200 } }));
const openAIReply = (verdictText: string) =>
  new Response(JSON.stringify({ model: "gpt-6.1-sol-2026-11-17", service_tier: "default", output: [{ type: "reasoning" }, { type: "message", content: [{ type: "output_text", text: verdictText }] }], usage: { input_tokens: 2000, output_tokens: 200 } }));

describe("the judging models", () => {
  it("are one Claude and one GPT, so a judge's own-family bias is offset by the other", () => {
    assert.deepEqual(Object.values(judgeModels).map((judge) => judge.provider).sort(), ["anthropic", "openai"]);
  });
});

describe("judgeRequest", () => {
  it("sends Claude the criteria and each image as base64, with the schema and effort", () => {
    const { url, headers, body } = judgeRequest(judgeModels.opus, parts, "medium", keys);

    assert.equal(url, "https://api.anthropic.com/v1/messages");
    assert.equal(headers["x-api-key"], "anthropic-key");
    assert.equal(body.model, "claude-opus-5-5");
    assert.deepEqual(body.messages, [
      { role: "user", content: [{ type: "text", text: "criteria" }, { type: "image", source: { type: "base64", media_type: "image/png", data: "QQ==" } }] },
    ]);
    assert.deepEqual((body.output_config as { effort: string }).effort, "medium");
    assert.deepEqual((body.output_config as { format: { type: string } }).format.type, "json_schema");
  });

  it("sends GPT the criteria and each image as a data URL, with the schema in strict mode and no service tier", () => {
    const { url, headers, body } = judgeRequest(judgeModels.sol, parts, "high", keys);

    assert.equal(url, "https://api.openai.com/v1/responses");
    assert.equal(headers.authorization, "Bearer openai-key");
    assert.equal(body.model, "gpt-6.1-sol");
    assert.deepEqual(body.input, [
      { role: "user", content: [{ type: "input_text", text: "criteria" }, { type: "input_image", image_url: "data:image/png;base64,QQ==", detail: "high" }] },
    ]);
    assert.deepEqual(body.reasoning, { effort: "high" });
    assert.equal((body.text as { format: { strict: boolean } }).format.strict, true);
    assert.ok(!("service_tier" in body));
  });
});

describe("requestJudgeVerdict", () => {
  it("reads Claude's verdict from its text block, past a thinking block, and prices the call", async () => {
    const { fetchImpl } = fakeFetch(anthropicReply('{"reason":"B is tighter","winner":"B"}'));

    const result = await requestJudgeVerdict(judgeModels.opus, parts, { keys, effort: "medium", fetchImpl });

    assert.ok(result.ok);
    assert.equal(result.winner, "B");
    assert.equal(result.reason, "B is tighter");
    assert.equal(costOfUsageLine(result.usage), (2000 * 4 + 200 * 20) / 1_000_000);
  });

  it("reads GPT's verdict from its output text, and prices the call at the tier OpenAI reported", async () => {
    const { fetchImpl } = fakeFetch(openAIReply('{"reason":"A names the parts","winner":"A"}'));

    const result = await requestJudgeVerdict(judgeModels.sol, parts, { keys, effort: "medium", fetchImpl });

    assert.ok(result.ok);
    assert.equal(result.winner, "A");
    assert.equal(costOfUsageLine(result.usage), (2000 * 2 + 200 * 10) / 1_000_000);
  });

  it("tries a 429 again and returns the verdict of the next attempt", async () => {
    const { fetchImpl, calls } = fakeFetch(new Response("slow down", { status: 429 }), new Response("oops", { status: 503 }), anthropicReply('{"reason":"","winner":"tie"}'));

    const result = await requestJudgeVerdict(judgeModels.opus, parts, { keys, effort: "medium", fetchImpl, retryDelayMs: 0 });

    assert.ok(result.ok && result.winner === "tie");
    assert.equal(calls.length, 3);
  });

  it("gives up after three attempts, naming the last status", async () => {
    const { fetchImpl, calls } = fakeFetch(new Response("", { status: 429 }), new Response("", { status: 429 }), new Response("", { status: 429 }));

    const result = await requestJudgeVerdict(judgeModels.opus, parts, { keys, effort: "medium", fetchImpl, retryDelayMs: 0 });

    assert.deepEqual(result, { ok: false, error: "HTTP 429" });
    assert.equal(calls.length, 3);
  });

  it("does not retry a 400, which would fail the same way", async () => {
    const { fetchImpl, calls } = fakeFetch(new Response('{"error":"bad schema"}', { status: 400 }));

    const result = await requestJudgeVerdict(judgeModels.sol, parts, { keys, effort: "medium", fetchImpl, retryDelayMs: 0 });

    assert.ok(!result.ok && result.error.startsWith("HTTP 400"));
    assert.equal(calls.length, 1);
  });

  it("reports a reply with no verdict instead of counting it", async () => {
    const { fetchImpl } = fakeFetch(anthropicReply('{"winner":"neither"}'));

    const result = await requestJudgeVerdict(judgeModels.opus, parts, { keys, effort: "medium", fetchImpl });

    assert.ok(!result.ok && result.error.startsWith("the reply held no verdict"));
  });
});

describe("parseDevVars", () => {
  it("reads values with and without quotes and skips comments and blanks", () => {
    const values = parseDevVars('# keys\nANTHROPIC_API_KEY="sk-a"\nOPENAI_API_KEY=sk-o\n\nELEVENLABS_VOICE_ID = "voice"\n');

    assert.deepEqual(values, { ANTHROPIC_API_KEY: "sk-a", OPENAI_API_KEY: "sk-o", ELEVENLABS_VOICE_ID: "voice" });
  });
});
