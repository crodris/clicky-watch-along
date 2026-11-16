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
});
