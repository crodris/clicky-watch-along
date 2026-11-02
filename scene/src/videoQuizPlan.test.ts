import { afterEach, describe, expect, it, vi } from "vitest";
import { handleVideoQuizPlan, parseVideoQuizPlan } from "../../worker/src/videoQuizPlan";

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

const validToolInput = { moments: [liverMoment, denticleMoment, poreMoment] };

function requestWithBody(body: unknown): Request {
  return new Request("https://worker.test/video-quiz-plan", {
    method: "POST",
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

function toolReply(input: unknown): Response {
  return new Response(
    JSON.stringify({ content: [{ type: "tool_use", name: "plan_quiz_moments", input }] }),
    { status: 200 },
  );
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("parseVideoQuizPlan", () => {
  it("accepts three spread moments and sorts them by time", () => {
    const result = parseVideoQuizPlan(
      { moments: [poreMoment, liverMoment, denticleMoment] },
      transcriptLines,
    );

    expect(result).toEqual({ ok: true, plan: validToolInput });
  });

  it("rejects a plan that does not have exactly three moments", () => {
    const result = parseVideoQuizPlan({ moments: [liverMoment, denticleMoment] }, transcriptLines);

    expect(result.ok).toBe(false);
  });

  it("rejects a pause that is not on a transcript line", () => {
    const result = parseVideoQuizPlan(
      { moments: [{ ...liverMoment, pauseAtSeconds: 61 }, denticleMoment, poreMoment] },
      transcriptLines,
    );

    expect(result.ok).toBe(false);
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

  it("rejects a question that contains the answer", () => {
    const result = parseVideoQuizPlan(
      {
        moments: [
          { ...liverMoment, question: "Let's pause here! What does the liver do for the shark?" },
          denticleMoment,
          poreMoment,
        ],
      },
      transcriptLines,
    );

    expect(result.ok).toBe(false);
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

  it("rejects function words that are not lowercase single words", () => {
    for (const functionWords of [["Floats"], ["stays afloat"], []]) {
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

  it("rejects a reply with no tool input", () => {
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

  it("forces the plan_quiz_moments tool and returns the validated plan", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => toolReply(validToolInput));
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleVideoQuizPlan(requestWithBody(validRequest), "key");

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(validToolInput);
    const sentBody: unknown = JSON.parse(String(fetchMock.mock.calls[0]?.[1].body));
    expect(sentBody).toMatchObject({
      model: "claude-haiku-5-5",
      tool_choice: { type: "tool", name: "plan_quiz_moments" },
    });
  });

  it("retries once and tells the model which rule it broke", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        toolReply({ moments: [{ ...liverMoment, pauseAtSeconds: 61 }, denticleMoment, poreMoment] }),
      )
      .mockResolvedValueOnce(toolReply(validToolInput));
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleVideoQuizPlan(requestWithBody(validRequest), "key");

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(validToolInput);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    const retryBody = String(fetchMock.mock.calls[1]?.[1].body);
    expect(retryBody).toContain("pauseAtSeconds 61 is not the seconds value of any transcript line");
  });

  it("returns 502 after two replies that break the contract", async () => {
    const fetchMock = vi.fn(async () => {
      return toolReply({ moments: [liverMoment] });
    });
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleVideoQuizPlan(requestWithBody(validRequest), "key");

    expect(response.status).toBe(502);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});
