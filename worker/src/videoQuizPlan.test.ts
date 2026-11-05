import { afterEach, describe, expect, it, vi } from "vitest";
import { z } from "zod";
import { handleVideoQuizPlan, parseVideoQuizPlan } from "./videoQuizPlan";

const transcriptLines = [
  { seconds: 0, text: "Welcome back to the channel." },
  { seconds: 12, text: "Today we look at sharks." },
  { seconds: 30, text: "Sharks have no swim bladder." },
  { seconds: 45, text: "Their huge liver is full of oil." },
  { seconds: 60, text: "Oil is lighter than water, so it keeps them afloat." },
  { seconds: 100, text: "Their skin is covered in tiny teeth called denticles." },
  { seconds: 120, text: "The denticles cut drag as water flows past." },
  { seconds: 170, text: "Sharks sense electricity through small pores." },
  { seconds: 190, text: "Those pores are the ampullae of Lorenzini." },
  { seconds: 200, text: "Thanks to our sponsor." },
];

const liverMoment = {
  pauseAtSeconds: 60,
  sourceLineSeconds: 0,
  question: "Let's pause here! What does this big oily organ do for the shark?",
  answerLabel: "liver",
  functionWords: ["floats", "oil", "buoyancy"],
  explanation: "The liver is full of oil, which is lighter than water, so it keeps the shark afloat.",
  subject: "great white shark liver",
};

const denticleMoment = {
  pauseAtSeconds: 120,
  sourceLineSeconds: 100,
  question: "Let's pause here! What are the tiny teeth on shark skin?",
  answerLabel: "denticles",
  functionWords: ["drag", "smooth", "faster"],
  explanation: "Denticles cut drag, so the shark swims faster.",
  subject: "shark skin denticles",
};

const poreMoment = {
  pauseAtSeconds: 190,
  sourceLineSeconds: 170,
  question: "Let's pause here! What do the small pores on a shark's snout sense?",
  answerLabel: "electricity",
  functionWords: ["hunt", "prey", "sense"],
  explanation: "The pores sense electricity from prey hidden in the sand.",
  subject: "shark snout pores",
};

const validPlan = { moments: [liverMoment, denticleMoment, poreMoment] };

function requestWithBody(body: unknown): Request {
  return new Request("https://worker.test/video-quiz-plan", {
    method: "POST",
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

function planReply(plan: unknown): Response {
  return new Response(
    JSON.stringify({ content: [{ type: "thinking", thinking: "" }, { type: "text", text: JSON.stringify(plan) }] }),
    { status: 200 },
  );
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("parseVideoQuizPlan", () => {
  it("accepts spread moments and sorts them by time", () => {
    const result = parseVideoQuizPlan(
      { moments: [poreMoment, liverMoment, denticleMoment] },
      transcriptLines,
    );

    expect(result).toEqual({ ok: true, plan: validPlan });
  });

  it("accepts however many moments the model picks", () => {
    const result = parseVideoQuizPlan({ moments: [liverMoment, denticleMoment] }, transcriptLines);

    expect(result).toEqual({ ok: true, plan: { moments: [liverMoment, denticleMoment] } });
  });

  it("rejects a plan with no moments", () => {
    const result = parseVideoQuizPlan({ moments: [] }, transcriptLines);

    expect(result.ok).toBe(false);
  });

  it("moves a pause between two lines to the next line start", () => {
    const result = parseVideoQuizPlan(
      { moments: [{ ...liverMoment, pauseAtSeconds: 52.5 }, denticleMoment, poreMoment] },
      transcriptLines,
    );

    expect(result).toEqual({ ok: true, plan: validPlan });
  });

  it("rejects a pause after the last line start", () => {
    const result = parseVideoQuizPlan(
      { moments: [liverMoment, denticleMoment, { ...poreMoment, pauseAtSeconds: 205 }] },
      transcriptLines,
    );

    expect(result).toEqual({ ok: false, error: "pauseAtSeconds 205 is after the last transcript line at 200" });
  });

  it("keeps a question whose answer is only part of a longer accented word", () => {
    const checkedPlan = parseVideoQuizPlan(
      {
        moments: [
          liverMoment,
          denticleMoment,
          { ...poreMoment, answerLabel: "nome", question: "Let's pause here! What does the shark's génome store?" },
        ],
      },
      transcriptLines,
    );

    expect(checkedPlan.ok && checkedPlan.plan.moments.length).toBe(3);
  });

  it("drops a question that contains its accented answer", () => {
    const checkedPlan = parseVideoQuizPlan(
      {
        moments: [
          liverMoment,
          denticleMoment,
          { ...poreMoment, answerLabel: "Résumé", question: "Let's pause here! What does the shark's résumé list?" },
        ],
      },
      transcriptLines,
    );

    expect(checkedPlan.ok && checkedPlan.plan.moments.length).toBe(2);
  });

  it("rejects a source time before the first transcript line", () => {
    const linesFromTheMiddle = transcriptLines.filter((transcriptLine) => transcriptLine.seconds >= 100);

    const result = parseVideoQuizPlan(
      { moments: [{ ...denticleMoment, sourceLineSeconds: 5 }, { ...poreMoment, pauseAtSeconds: 200, question: "Let's pause here! What came last?", answerLabel: "pores" }] },
      linesFromTheMiddle,
    );

    expect(result).toEqual({ ok: false, error: "sourceLineSeconds 5 is before the first transcript line at 100" });
  });

  it("moves a source time between two lines to the line playing then", () => {
    const result = parseVideoQuizPlan(
      { moments: [{ ...liverMoment, sourceLineSeconds: 5 }, denticleMoment, poreMoment] },
      transcriptLines,
    );

    expect(result).toEqual({ ok: true, plan: validPlan });
  });

  it("rejects a plan whose first pause is past the first minute", () => {
    const checkedPlan = parseVideoQuizPlan(
      { moments: [{ ...liverMoment, pauseAtSeconds: 61 }, denticleMoment, poreMoment] },
      transcriptLines,
    );

    expect(checkedPlan.ok).toBe(false);
  });

  it("rejects a moment built from a line the learner has not heard yet", () => {
    const checkedPlan = parseVideoQuizPlan(
      { moments: [{ ...liverMoment, sourceLineSeconds: 100 }, denticleMoment, poreMoment] },
      transcriptLines,
    );

    expect(checkedPlan.ok).toBe(false);
  });

  it("counts timing rules from where the transcript starts", () => {
    const linesFromTheMiddle = transcriptLines.filter((transcriptLine) => transcriptLine.seconds >= 100);

    const checkedPlan = parseVideoQuizPlan(
      { moments: [denticleMoment, poreMoment, { ...poreMoment, pauseAtSeconds: 200, question: "Let's pause here! What came last?", answerLabel: "pores" }] },
      linesFromTheMiddle,
    );

    expect(checkedPlan.ok).toBe(true);
  });

  it("rejects a pause inside the first 20 seconds", () => {
    const result = parseVideoQuizPlan(
      { moments: [{ ...liverMoment, pauseAtSeconds: 12 }, denticleMoment, poreMoment] },
      transcriptLines,
    );

    expect(result.ok).toBe(false);
  });

  it("accepts a pause at exactly 20 seconds", () => {
    const linesWithTwentySecondMark = [...transcriptLines, { seconds: 20, text: "Sharks are old." }];

    const result = parseVideoQuizPlan(
      { moments: [{ ...liverMoment, pauseAtSeconds: 20 }, denticleMoment, poreMoment] },
      linesWithTwentySecondMark,
    );

    expect(result.ok).toBe(true);
  });

  it("rejects moments that are bunched together", () => {
    const result = parseVideoQuizPlan(
      { moments: [{ ...liverMoment, pauseAtSeconds: 45 }, liverMoment, denticleMoment] },
      transcriptLines,
    );

    expect(result.ok).toBe(false);
  });

  it("drops only the stop whose question contains its answer", () => {
    const checkedPlan = parseVideoQuizPlan(
      {
        moments: [
          liverMoment,
          denticleMoment,
          { ...poreMoment, question: "Let's pause here! Do pores sense electricity?" },
        ],
      },
      transcriptLines,
    );

    expect(checkedPlan.ok && checkedPlan.plan.moments.length).toBe(2);
  });

  it("allows an answer label that is only part of a longer word in the question", () => {
    const result = parseVideoQuizPlan(
      {
        moments: [
          { ...liverMoment, question: "Let's pause here! What does the shark's delivery system of oil do?" },
          denticleMoment,
          poreMoment,
        ],
      },
      transcriptLines,
    );

    expect(result.ok).toBe(true);
  });

  it("rejects an answer label longer than two words", () => {
    const result = parseVideoQuizPlan(
      { moments: [{ ...liverMoment, answerLabel: "oily shark liver" }, denticleMoment, poreMoment] },
      transcriptLines,
    );

    expect(result.ok).toBe(false);
  });

  it("lowercases function words and keeps phrases whole instead of rejecting them", () => {
    const result = parseVideoQuizPlan(
      { moments: [{ ...liverMoment, functionWords: ["Floats", " Stays Afloat ", "one-way", "CO2", "!!"] }, denticleMoment, poreMoment] },
      transcriptLines,
    );

    expect(result.ok && result.plan.moments[0]?.functionWords).toEqual(["floats", "stays afloat", "one-way", "co2"]);
  });

  it("rejects function words with no letters or digits", () => {
    for (const functionWords of [[], ["!!", " "]]) {
      const result = parseVideoQuizPlan(
        { moments: [{ ...liverMoment, functionWords }, denticleMoment, poreMoment] },
        transcriptLines,
      );

      expect(result.ok).toBe(false);
    }
  });

  it("rejects a moment with a missing field", () => {
    const { subject: _subject, ...momentWithoutSubject } = liverMoment;

    const result = parseVideoQuizPlan(
      { moments: [momentWithoutSubject, denticleMoment, poreMoment] },
      transcriptLines,
    );

    expect(result.ok).toBe(false);
  });

  it("rejects a reply with no plan", () => {
    expect(parseVideoQuizPlan(undefined, transcriptLines).ok).toBe(false);
  });
});

describe("handleVideoQuizPlan", () => {
  const validRequest = { title: "How sharks stay afloat", transcriptLines };

  it("returns 400 for a body that is not JSON", async () => {
    const response = await handleVideoQuizPlan(requestWithBody("not json"), "key");

    expect(response.status).toBe(400);
  });

  it("returns 400 when the transcript is empty", async () => {
    const response = await handleVideoQuizPlan(
      requestWithBody({ title: "Empty", transcriptLines: [] }),
      "key",
    );

    expect(response.status).toBe(400);
  });

  it("asks Sonnet for the plan as JSON and returns the validated plan", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => planReply(validPlan));
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleVideoQuizPlan(requestWithBody(validRequest), "key");

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(validPlan);
    const sentBody: unknown = JSON.parse(String(fetchMock.mock.calls[0]?.[1].body));
    expect(sentBody).toMatchObject({
      model: "claude-sonnet-5-5",
      output_config: { format: { type: "json_schema" } },
    });
    expect(sentBody).not.toHaveProperty("tool_choice");
  });

  it("retries when the reply text is not JSON", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({ content: [{ type: "text", text: "Sure! Here is the plan" }] })))
      .mockResolvedValueOnce(planReply(validPlan));
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleVideoQuizPlan(requestWithBody(validRequest), "key");

    expect(response.status).toBe(200);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("retries once, tells the model which rule it broke, and logs the rejection", async () => {
    const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        planReply({ moments: [{ ...liverMoment, pauseAtSeconds: 100 }, denticleMoment, poreMoment] }),
      )
      .mockResolvedValueOnce(planReply(validPlan));
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleVideoQuizPlan(requestWithBody(validRequest), "key");

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(validPlan);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    const rejection = "The first pause at 100 is more than 60 seconds after the first transcript line";
    expect(String(fetchMock.mock.calls[1]?.[1].body)).toContain(rejection);
    expect(consoleErrorSpy).toHaveBeenCalledWith(`[/video-quiz-plan] attempt 1 rejected: ${rejection}`);
  });

  it("sends a retry the same cached transcript block, with the rejection after it", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(planReply({ moments: [] }))
      .mockResolvedValueOnce(planReply(validPlan));
    vi.stubGlobal("fetch", fetchMock);

    await handleVideoQuizPlan(requestWithBody(validRequest), "key");

    const sentRequestSchema = z.object({ messages: z.array(z.object({ content: z.array(z.unknown()) })).min(1) });
    const userContentOfCall = (callIndex: number): unknown[] => {
      const sentBody: unknown = JSON.parse(String(fetchMock.mock.calls[callIndex]?.[1].body));
      return sentRequestSchema.parse(sentBody).messages[0]?.content ?? [];
    };
    const firstContent = userContentOfCall(0);
    const retryContent = userContentOfCall(1);
    expect(firstContent).toHaveLength(1);
    expect(firstContent[0]).toMatchObject({ cache_control: { type: "ephemeral" } });
    expect(retryContent[0]).toEqual(firstContent[0]);
    expect(retryContent[1]).toMatchObject({ text: expect.stringContaining("Your previous reply was rejected") });
  });

  it("returns 502 after three replies that break the contract", async () => {
    const fetchMock = vi.fn(async () => {
      return planReply({ moments: [] });
    });
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleVideoQuizPlan(requestWithBody(validRequest), "key");

    expect(response.status).toBe(502);
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });
});
