import { afterEach, describe, expect, it, vi } from "vitest";
import { handleWatchMoment, parseWatchMomentDecision } from "../../worker/src/watchMoment";

const validPause = {
  shouldPause: true,
  question: "Let's pause here! What does this big oily organ do for the shark?",
  answerLabel: "liver",
  functionWords: ["floats", "oil", "buoyancy"],
  explanation: "The liver is full of oil, which is lighter than water, so it keeps the shark afloat.",
  subject: "great white shark liver",
};

const validRequest = {
  transcript: "Sharks have no swim bladder. Their huge liver is full of oil.",
  newTranscript: "Their huge liver is full of oil.",
  alreadyAskedQuestions: [],
  screenshotBase64: "AAAA",
  screenshotMediaType: "image/jpeg",
};

function requestWithBody(body: unknown): Request {
  return new Request("https://worker.test/watch-moment", {
    method: "POST",
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("parseWatchMomentDecision", () => {
  it("returns only shouldPause when the model declines", () => {
    const result = parseWatchMomentDecision({ shouldPause: false, question: "ignored" });

    expect(result).toEqual({ ok: true, response: { shouldPause: false } });
  });

  it("accepts a complete pause", () => {
    expect(parseWatchMomentDecision(validPause)).toEqual({ ok: true, response: validPause });
  });

  it("rejects a question that contains the answer", () => {
    const result = parseWatchMomentDecision({
      ...validPause,
      question: "Let's pause here! What does the liver do for the shark?",
    });

    expect(result.ok).toBe(false);
  });

  it("allows an answer label that is only part of a longer word in the question", () => {
    const result = parseWatchMomentDecision({
      ...validPause,
      question: "Let's pause here! What does the shark's delivery system of oil do?",
    });

    expect(result.ok).toBe(true);
  });

  it("rejects an answer label longer than two words", () => {
    const result = parseWatchMomentDecision({ ...validPause, answerLabel: "oily shark liver" });

    expect(result.ok).toBe(false);
  });

  it("rejects function words that are not lowercase single words", () => {
    expect(parseWatchMomentDecision({ ...validPause, functionWords: ["Floats"] }).ok).toBe(false);
    expect(parseWatchMomentDecision({ ...validPause, functionWords: ["stays afloat"] }).ok).toBe(false);
    expect(parseWatchMomentDecision({ ...validPause, functionWords: [] }).ok).toBe(false);
  });

  it("rejects a pause with a missing field", () => {
    const { subject: _subject, ...pauseWithoutSubject } = validPause;

    expect(parseWatchMomentDecision(pauseWithoutSubject).ok).toBe(false);
  });

  it("rejects a reply with no tool input", () => {
    expect(parseWatchMomentDecision(undefined).ok).toBe(false);
  });
});

describe("handleWatchMoment", () => {
  it("returns 400 for a body that is not JSON", async () => {
    const response = await handleWatchMoment(requestWithBody("not json"), "key");

    expect(response.status).toBe(400);
  });

  it("returns 400 when a screenshot media type is not jpeg", async () => {
    const response = await handleWatchMoment(
      requestWithBody({ ...validRequest, screenshotMediaType: "image/png" }),
      "key",
    );

    expect(response.status).toBe(400);
  });

  it("forces the decide_pause tool and returns the validated pause", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => {
      return new Response(
        JSON.stringify({ content: [{ type: "tool_use", name: "decide_pause", input: validPause }] }),
        { status: 200 },
      );
    });
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleWatchMoment(requestWithBody(validRequest), "key");

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(validPause);
    const sentBody: unknown = JSON.parse(String(fetchMock.mock.calls[0]?.[1].body));
    expect(sentBody).toMatchObject({ tool_choice: { type: "tool", name: "decide_pause" } });
  });

  it("retries once when the first model reply breaks the contract", async () => {
    const toolReply = (input: unknown) => {
      return new Response(
        JSON.stringify({ content: [{ type: "tool_use", name: "decide_pause", input }] }),
        { status: 200 },
      );
    };
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(toolReply({ ...validPause, answerLabel: "a b c" }))
      .mockResolvedValueOnce(toolReply(validPause));
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleWatchMoment(requestWithBody(validRequest), "key");

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(validPause);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("returns 502 after two replies that break the contract", async () => {
    const fetchMock = vi.fn(async () => {
      return new Response(
        JSON.stringify({
          content: [{ type: "tool_use", name: "decide_pause", input: { ...validPause, answerLabel: "a b c" } }],
        }),
        { status: 200 },
      );
    });
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleWatchMoment(requestWithBody(validRequest), "key");

    expect(response.status).toBe(502);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});
