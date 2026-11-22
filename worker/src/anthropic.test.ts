import { afterEach, describe, expect, it, vi } from "vitest";
import { z } from "zod";
import { logModelUsage, requestAnthropicMessage, zodIssuesOnOneLine } from "./anthropic";

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("requestAnthropicMessage", () => {
  it("answers 502 with a fixed message when the fetch itself fails, so raw error text never reaches the app", async () => {
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new TypeError("getaddrinfo ENOTFOUND api.anthropic.com");
      }),
    );

    const anthropicMessage = await requestAnthropicMessage("anthropic-key", "/test-route", { model: "m", messages: [] });

    expect(anthropicMessage.ok).toBe(false);
    if (!anthropicMessage.ok) {
      expect(anthropicMessage.response.status).toBe(502);
      expect(await anthropicMessage.response.json()).toEqual({ error: "Anthropic could not be reached" });
    }
  });

  it("answers 502 for a reply with no content list, for every route that calls it", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify({ stop_reason: "end_turn" }))));

    const anthropicMessage = await requestAnthropicMessage("anthropic-key", "/test-route", { model: "m", messages: [] });

    expect(anthropicMessage.ok).toBe(false);
    if (!anthropicMessage.ok) {
      expect(anthropicMessage.response.status).toBe(502);
      expect(await anthropicMessage.response.json()).toEqual({ error: "Anthropic response had no content list" });
    }
  });

  it("keeps every field of each block and the stop reason, which a caller may send back to Anthropic unchanged", async () => {
    const toolUseBlock = { type: "tool_use", id: "t1", name: "finish", input: { spokenSummary: "Done." } };
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify({ content: [toolUseBlock], stop_reason: "tool_use", usage: {} }))),
    );

    const anthropicMessage = await requestAnthropicMessage("anthropic-key", "/test-route", { model: "m", messages: [] });

    expect(anthropicMessage.ok).toBe(true);
    if (anthropicMessage.ok) {
      expect(anthropicMessage.message.content).toEqual([toolUseBlock]);
      expect(anthropicMessage.message.stop_reason).toBe("tool_use");
    }
  });
});

describe("logModelUsage", () => {
  it("logs the model and the usage fields of an Anthropic reply as they are", () => {
    const logMock = vi.spyOn(console, "log").mockImplementation(() => undefined);

    logModelUsage("/judge-answer", { model: "claude-sonnet-5-5", usage: { input_tokens: 10, output_tokens: 2, service_tier: "standard" } });

    expect(logMock).toHaveBeenCalledWith('[/judge-answer] usage {"model":"claude-sonnet-5-5","input_tokens":10,"output_tokens":2,"service_tier":"standard"}');
  });

  it("adds the service tier OpenAI names at the top of its reply, which the benchmark prices by", () => {
    const logMock = vi.spyOn(console, "log").mockImplementation(() => undefined);

    logModelUsage("/live-scene", { model: "gpt-6.1-sol", service_tier: "ultrafast", usage: { input_tokens: 10, output_tokens: 2 } });

    expect(logMock).toHaveBeenCalledWith('[/live-scene] usage {"model":"gpt-6.1-sol","input_tokens":10,"output_tokens":2,"service_tier":"ultrafast"}');
  });
});

describe("zodIssuesOnOneLine", () => {
  it("keeps model-written line breaks out of the line, so no issue can forge a log line", () => {
    const parsed = z.object({ kind: z.enum(["wallArt", "other"]) }).strict().safeParse({ kind: "a\nfake log line\u2028and\u2029more\r\u0085end", extra: 1 });

    expect(parsed.success).toBe(false);
    if (!parsed.success) {
      const line = zodIssuesOnOneLine(parsed.error);
      expect(line).toContain("fake log line");
      expect(line).not.toMatch(/[\r\n\v\f\u0085\u2028\u2029]/);
    }
  });
});
