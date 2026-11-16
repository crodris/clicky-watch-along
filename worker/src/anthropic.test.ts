import { afterEach, describe, expect, it, vi } from "vitest";
import { requestAnthropicMessage } from "./anthropic";

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

  it("keeps every field of each block and the stop reason, which /background-agent sends back unchanged", async () => {
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
