import assert from "node:assert/strict";
import { describe, it, mock } from "node:test";
import { costOfUsageLine, usageAfterChatStreamEvent, usageLineFromUsageObject, type UsageLine } from "./usage.ts";

function usageLine(overrides: Partial<UsageLine>): UsageLine {
  return {
    route: "/judge-answer",
    model: "claude-sonnet-5-5",
    serviceTier: undefined,
    inputTokens: 0,
    cacheWriteTokens: 0,
    cacheReadTokens: 0,
    outputTokens: 0,
    ...overrides,
  };
}

function assertCost(actualCost: number | null, expectedCost: number) {
  assert.notEqual(actualCost, null);
  assert.ok(Math.abs((actualCost ?? 0) - expectedCost) < 1e-9, `expected ${expectedCost}, got ${actualCost}`);
}

describe("costOfUsageLine", () => {
  it("prices a Claude call with cache writes and reads at their own rates", () => {
    const cost = costOfUsageLine(usageLine({ model: "claude-sonnet-5-5", inputTokens: 1000, cacheWriteTokens: 200, cacheReadTokens: 5000, outputTokens: 300 }));

    assertCost(cost, (1000 * 2 + 200 * 2.5 + 5000 * 0.1 + 300 * 10) / 1_000_000);
  });

  it("prices a GPT call at the standard tier, with cached tokens counted inside the input", () => {
    const cost = costOfUsageLine(usageLine({ model: "gpt-6.1-sol", serviceTier: "default", inputTokens: 1000, cacheReadTokens: 400, outputTokens: 100 }));

    assertCost(cost, (600 * 2 + 400 * 0.1 + 100 * 10) / 1_000_000);
  });

  it("prices Ultrafast at 6 times the standard tier", () => {
    const standardCost = costOfUsageLine(usageLine({ model: "gpt-6-sol", serviceTier: "default", inputTokens: 1000, outputTokens: 100 }));
    const ultrafastCost = costOfUsageLine(usageLine({ model: "gpt-6-sol", serviceTier: "ultrafast", inputTokens: 1000, outputTokens: 100 }));

    assertCost(ultrafastCost, (standardCost ?? 0) * 6);
  });

  it("matches a dated snapshot to its model, and 6.2 Astra to its own price", () => {
    assertCost(
      costOfUsageLine(usageLine({ model: "gpt-6.2-astra-2026-11-17", serviceTier: "default", inputTokens: 1000, outputTokens: 100 })),
      (1000 * 8 + 100 * 40) / 1_000_000,
    );
  });

  it("prices a GPT call that names no tier as standard, except a live scene, which the Worker always asks to be Ultrafast", () => {
    const standardCost = costOfUsageLine(usageLine({ model: "gpt-6.1-sol", serviceTier: "default", inputTokens: 1000, outputTokens: 100 }));

    assertCost(costOfUsageLine(usageLine({ model: "gpt-6.1-sol", inputTokens: 1000, outputTokens: 100 })), standardCost ?? 0);
    assertCost(costOfUsageLine(usageLine({ route: "/live-scene", model: "gpt-6.1-sol", inputTokens: 1000, outputTokens: 100 })), (standardCost ?? 0) * 6);
  });

  it("records a model or a tier with no price as unknown instead of guessing", () => {
    const warn = mock.method(console, "warn", () => undefined);

    assert.equal(costOfUsageLine(usageLine({ model: "gpt-6.1-terra", inputTokens: 10 })), null);
    assert.equal(costOfUsageLine(usageLine({ model: "gpt-6-luna", serviceTier: "flex", inputTokens: 10 })), null);
    assert.equal(warn.mock.callCount(), 2);
    warn.mock.restore();
  });
});

describe("usageLineFromUsageObject", () => {
  it("reads OpenAI's counts, cached tokens, and tier", () => {
    const line = usageLineFromUsageObject("/judge-answer", {
      model: "gpt-6-luna",
      service_tier: "ultrafast",
      input_tokens: 900,
      input_tokens_details: { cached_tokens: 512 },
      output_tokens: 40,
    });

    assert.deepEqual(line, {
      route: "/judge-answer",
      model: "gpt-6-luna",
      serviceTier: "ultrafast",
      inputTokens: 900,
      cacheWriteTokens: 0,
      cacheReadTokens: 512,
      outputTokens: 40,
    });
  });

  it("reads Anthropic's cache fields", () => {
    const line = usageLineFromUsageObject("/landmark", { model: "claude-haiku-5-5", input_tokens: 5, cache_creation_input_tokens: 7, cache_read_input_tokens: 9, output_tokens: 3 });

    assert.equal(line.cacheWriteTokens, 7);
    assert.equal(line.cacheReadTokens, 9);
    assert.equal(line.serviceTier, undefined);
  });
});

describe("usageAfterChatStreamEvent", () => {
  it("builds an OpenAI call's usage from the zero counts at the start and the full counts in the last message_delta", () => {
    const streamEvents = [
      { type: "message_start", message: { model: "gpt-6-luna", usage: { input_tokens: 0, output_tokens: 0 } } },
      { type: "content_block_delta", delta: { type: "text_delta", text: "hi" } },
      {
        type: "message_delta",
        delta: { stop_reason: "end_turn" },
        usage: { input_tokens: 900, input_tokens_details: { cached_tokens: 512 }, output_tokens: 40, service_tier: "ultrafast" },
      },
    ];

    const usageObject = streamEvents.reduce<Record<string, unknown>>(usageAfterChatStreamEvent, {});

    assert.deepEqual(usageLineFromUsageObject("/chat", usageObject), {
      route: "/chat",
      model: "gpt-6-luna",
      serviceTier: "ultrafast",
      inputTokens: 900,
      cacheWriteTokens: 0,
      cacheReadTokens: 512,
      outputTokens: 40,
    });
  });

  it("keeps a Claude call's input and cache counts from the start and takes its output count from the delta", () => {
    const streamEvents = [
      { type: "message_start", message: { model: "claude-sonnet-5-5", usage: { input_tokens: 40, cache_read_input_tokens: 800, output_tokens: 1 } } },
      { type: "message_delta", usage: { output_tokens: 60 } },
    ];

    const usageObject = streamEvents.reduce<Record<string, unknown>>(usageAfterChatStreamEvent, {});

    assert.deepEqual(usageLineFromUsageObject("/chat", usageObject), {
      route: "/chat",
      model: "claude-sonnet-5-5",
      serviceTier: undefined,
      inputTokens: 40,
      cacheWriteTokens: 0,
      cacheReadTokens: 800,
      outputTokens: 60,
    });
  });
});
