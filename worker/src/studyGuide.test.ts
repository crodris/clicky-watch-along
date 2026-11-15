import { afterEach, describe, expect, it, vi } from "vitest";
import {
  handleStudyGuide,
  parseStudyGuide,
  signedPageHandle,
  studyGuidePageBlocks,
  videoTimestampURL,
  type NotionBlock,
  type QuizResult,
  type StudyGuide,
} from "./studyGuide";

const videoURL = "https://www.youtube.com/watch?v=abc123";
const videoTitle = "How a jet engine works";

const transcriptLines = [
  { seconds: 10, text: "A jet engine pulls in air." },
  { seconds: 40, text: "The compressor squeezes it." },
  { seconds: 83, text: "Fuel burns in the combustor." },
  { seconds: 120, text: "The hot gas spins the turbine." },
];

const validGuide: StudyGuide = {
  title: "Jet engines",
  summary: "A jet engine pulls in air, squeezes it, burns fuel, and pushes the gas out.",
  sections: [{ heading: "Burning", points: [{ text: "Fuel burns in the combustor.", seconds: 83 }] }],
  keyTerms: [{ term: "Combustor", meaning: "The room where fuel burns.", seconds: 83 }],
};

const gotItResult: QuizResult = {
  question: "What squeezes the air?",
  answerLabel: "Compressor",
  explanation: "The compressor squeezes the air.",
  askedAtSeconds: 40,
  result: "gotIt",
};
const missedResult: QuizResult = {
  question: "Where does fuel burn?",
  answerLabel: "Combustor",
  explanation: "Fuel burns in the combustor.",
  askedAtSeconds: 83,
  result: "missed",
};
const skippedResult: QuizResult = { ...missedResult, question: "What spins?", answerLabel: "Turbine", askedAtSeconds: 120, result: "skipped" };

function guideWithSections(sectionCount: number): unknown {
  return {
    ...validGuide,
    sections: Array.from({ length: sectionCount }, (_, sectionIndex) => ({
      heading: `Section ${sectionIndex}`,
      points: [{ text: "A point.", seconds: 40 }],
    })),
  };
}

function richTextOf(block: NotionBlock) {
  switch (block.type) {
    case "paragraph":
      return block.paragraph.rich_text;
    case "heading_2":
      return block.heading_2.rich_text;
    case "bulleted_list_item":
      return block.bulleted_list_item.rich_text;
  }
}

function plainTextOf(block: NotionBlock): string {
  return richTextOf(block)
    .map((richTextItem) => richTextItem.text.content)
    .join("");
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("parseStudyGuide", () => {
  it("snaps a point between two lines to the earlier line", () => {
    const parsedGuide = parseStudyGuide(
      {
        ...validGuide,
        sections: [{ heading: "Burning", points: [{ text: "Fuel burns.", seconds: 100 }] }],
        keyTerms: [{ term: "Turbine", meaning: "Spins.", seconds: 121.5 }],
      },
      transcriptLines,
    );

    expect(parsedGuide).toMatchObject({
      ok: true,
      guide: {
        sections: [{ points: [{ seconds: 83 }] }],
        keyTerms: [{ seconds: 120 }],
      },
    });
  });

  it("rejects a time before the first line", () => {
    const parsedGuide = parseStudyGuide(
      { ...validGuide, sections: [{ heading: "Intro", points: [{ text: "Air.", seconds: 5 }] }] },
      transcriptLines,
    );

    expect(parsedGuide).toEqual({ ok: false, error: "seconds 5 is before the first transcript line at 10" });
  });

  it("rejects 7 sections and accepts 6", () => {
    expect(parseStudyGuide(guideWithSections(7), transcriptLines).ok).toBe(false);
    expect(parseStudyGuide(guideWithSections(6), transcriptLines).ok).toBe(true);
  });
});

describe("videoTimestampURL", () => {
  it("replaces a t parameter the URL already has", () => {
    expect(videoTimestampURL("https://www.youtube.com/watch?v=abc123&t=5s", 83.9)).toBe(
      "https://www.youtube.com/watch?v=abc123&t=83s",
    );
  });

  it("keeps the host of a youtu.be link", () => {
    expect(videoTimestampURL("https://youtu.be/abc123", 83)).toBe("https://youtu.be/abc123?t=83s");
  });
});

describe("studyGuidePageBlocks", () => {
  it("opens with the linked video title and the summary", () => {
    const blocks = studyGuidePageBlocks(validGuide, [], videoTitle, videoURL);

    expect(richTextOf(blocks[0])).toEqual([
      { type: "text", text: { content: "Study guide for " } },
      { type: "text", text: { content: videoTitle, link: { url: videoURL } } },
    ]);
    expect(plainTextOf(blocks[1])).toBe(validGuide.summary);
  });

  it("leaves out the review section when the learner got every question", () => {
    const blocks = studyGuidePageBlocks(validGuide, [gotItResult], videoTitle, videoURL);

    expect(blocks.map(plainTextOf)).not.toContain("Review these first");
  });

  it("lists only the missed and skipped questions under Review these first", () => {
    const blocks = studyGuidePageBlocks(validGuide, [gotItResult, missedResult, skippedResult], videoTitle, videoURL);

    const reviewHeadingIndex = blocks.findIndex((block) => plainTextOf(block) === "Review these first");
    expect(reviewHeadingIndex).toBe(2);
    const reviewItems = blocks.slice(reviewHeadingIndex + 1, reviewHeadingIndex + 3).map(plainTextOf);
    expect(reviewItems).toEqual([
      "Where does fuel burn?\nAnswer: Combustor. Fuel burns in the combustor. (1:23)",
      "What spins?\nAnswer: Turbine. Fuel burns in the combustor. (2:00)",
    ]);
    expect(blocks.map(plainTextOf).join("\n")).not.toContain("What squeezes the air?");
  });

  it("links a point's timestamp with t=83s and shows it as (1:23)", () => {
    const blocks = studyGuidePageBlocks(validGuide, [], videoTitle, videoURL);

    const pointItems = richTextOf(blocks[3]);
    expect(blocks[3].type).toBe("bulleted_list_item");
    expect(pointItems[1]).toEqual({
      type: "text",
      text: { content: " (1:23)", link: { url: "https://www.youtube.com/watch?v=abc123&t=83s" } },
    });
  });

  it("shows a timestamp past an hour as h:mm:ss", () => {
    const longGuide = { ...validGuide, sections: [{ heading: "Late", points: [{ text: "Late.", seconds: 3723 }] }] };

    const blocks = studyGuidePageBlocks(longGuide, [], videoTitle, videoURL);

    expect(richTextOf(blocks[3])[1].text.content).toBe(" (1:02:03)");
  });

  it("writes a key term in bold, then its meaning and a timestamp link", () => {
    const blocks = studyGuidePageBlocks(validGuide, [], videoTitle, videoURL);

    const keyTermsHeadingIndex = blocks.findIndex((block) => plainTextOf(block) === "Key terms");
    expect(keyTermsHeadingIndex).toBeGreaterThan(0);
    const [termItem, meaningItem, linkItem] = richTextOf(blocks[keyTermsHeadingIndex + 1]);
    expect(termItem).toEqual({ type: "text", text: { content: "Combustor" }, annotations: { bold: true } });
    expect(meaningItem.text.content).toBe(": The room where fuel burns.");
    expect(linkItem.text.content).toBe(" (1:23)");
  });

  it("leaves out the key terms heading when the video defines none", () => {
    const blocks = studyGuidePageBlocks({ ...validGuide, keyTerms: [] }, [], videoTitle, videoURL);

    expect(blocks.map(plainTextOf)).not.toContain("Key terms");
  });

  it("cuts a 2500 character point to 2000 characters", () => {
    const longPointGuide = {
      ...validGuide,
      sections: [{ heading: "Long", points: [{ text: "a".repeat(2500), seconds: 83 }] }],
    };

    const blocks = studyGuidePageBlocks(longPointGuide, [], videoTitle, videoURL);

    expect(richTextOf(blocks[3])[0].text.content).toHaveLength(2000);
  });

  it("stays under 100 blocks at the largest guide", () => {
    const largestGuide: StudyGuide = {
      ...validGuide,
      sections: Array.from({ length: 6 }, (_, sectionIndex) => ({
        heading: `Section ${sectionIndex}`,
        points: Array.from({ length: 6 }, (_, pointIndex) => ({ text: `Point ${pointIndex}`, seconds: 40 })),
      })),
      keyTerms: Array.from({ length: 10 }, (_, termIndex) => ({ term: `Term ${termIndex}`, meaning: "Means.", seconds: 40 })),
    };
    const twentyMissedResults = Array.from({ length: 20 }, () => missedResult);

    const blocks = studyGuidePageBlocks(largestGuide, twentyMissedResults, videoTitle, videoURL);

    expect(blocks.length).toBeLessThan(100);
  });
});

describe("handleStudyGuide", () => {
  const notionEnvironment = {
    ANTHROPIC_API_KEY: "anthropic-key",
    NOTION_API_KEY: "notion-key",
  };

  const validRequestBody = { videoTitle, videoURL, transcriptLines, quizResults: [missedResult] };

  function requestWithBody(body: unknown): Request {
    return new Request("https://worker.test/study-guide", { method: "POST", body: JSON.stringify(body) });
  }

  /** Answers Anthropic with the guide, a Notion create with a page, and a Notion trash with whatever the test chose. */
  function stubFetch(options: { createStatus?: number; trashStatus?: number } = {}) {
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const requestedURL = String(url);
      if (requestedURL.startsWith("https://api.anthropic.com/")) {
        return new Response(JSON.stringify({ content: [{ type: "text", text: JSON.stringify(validGuide) }] }));
      }
      if (init?.method === "POST" && requestedURL === "https://api.notion.com/v1/pages") {
        const createStatus = options.createStatus ?? 200;
        return createStatus === 200
          ? new Response(JSON.stringify({ id: "new-page-id", url: "https://notion.so/new-page-id" }))
          : new Response(JSON.stringify({ message: "validation_error" }), { status: createStatus });
      }
      if (init?.method === "PATCH") {
        return new Response("{}", { status: options.trashStatus ?? 200 });
      }
      throw new Error(`Unexpected request to ${requestedURL}`);
    });
    vi.stubGlobal("fetch", fetchMock);
    return fetchMock;
  }

  function callsTo(fetchMock: ReturnType<typeof stubFetch>, hostName: string) {
    return fetchMock.mock.calls.filter(([url]) => new URL(String(url)).hostname === hostName);
  }

  it("answers 400 for a videoURL that is not on YouTube", async () => {
    const fetchMock = stubFetch();

    const response = await handleStudyGuide(
      requestWithBody({ ...validRequestBody, videoURL: "https://vimeo.com/123" }),
      notionEnvironment,
    );

    expect(response.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("accepts a video on a YouTube subdomain and refuses a host that only ends in youtube.com", async () => {
    stubFetch();

    const subdomainResponse = await handleStudyGuide(
      requestWithBody({ ...validRequestBody, videoURL: "https://music.youtube.com/watch?v=abc123" }),
      notionEnvironment,
    );
    const lookalikeResponse = await handleStudyGuide(
      requestWithBody({ ...validRequestBody, videoURL: "https://notyoutube.com/watch?v=abc123" }),
      notionEnvironment,
    );

    expect(subdomainResponse.status).toBe(200);
    expect(lookalikeResponse.status).toBe(400);
  });

  it("answers 400 for a transcript past the line limit, before any model or Notion call", async () => {
    const fetchMock = stubFetch();
    const tooManyLines = Array.from({ length: 10_001 }, (_, lineIndex) => ({ seconds: lineIndex, text: "line" }));

    const response = await handleStudyGuide(
      requestWithBody({ ...validRequestBody, transcriptLines: tooManyLines }),
      notionEnvironment,
    );

    expect(response.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("answers 503 and never calls Anthropic when the Notion key is missing", async () => {
    const fetchMock = stubFetch();

    const response = await handleStudyGuide(requestWithBody(validRequestBody), {
      ...notionEnvironment,
      NOTION_API_KEY: undefined,
    });

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "Notion is not connected" });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("drafts with one Anthropic call, creates one private page, and returns its signed handle and the guide", async () => {
    const fetchMock = stubFetch();

    const response = await handleStudyGuide(requestWithBody(validRequestBody), notionEnvironment);

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      pageHandle: await signedPageHandle("notion-key", "new-page-id"),
      pageURL: "https://notion.so/new-page-id",
      guide: validGuide,
    });
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(callsTo(fetchMock, "api.anthropic.com")).toHaveLength(1);
    const [notionURL, notionInit] = callsTo(fetchMock, "api.notion.com")[0];
    expect(notionURL).toBe("https://api.notion.com/v1/pages");
    expect(notionInit?.headers).toMatchObject({
      authorization: "Bearer notion-key",
      "notion-version": "2026-03-11",
    });
    expect(JSON.parse(String(notionInit?.body))).toMatchObject({
      parent: { type: "workspace", workspace: true },
      properties: { title: { title: [{ text: { content: "Jet engines" } }] } },
      children: expect.arrayContaining([expect.objectContaining({ type: "heading_2" })]),
    });
  });

  it("sends the quiz results, focus, and revision after the cached transcript", async () => {
    const fetchMock = stubFetch();

    await handleStudyGuide(
      requestWithBody({
        ...validRequestBody,
        focus: "only the combustor",
        revision: { pageHandle: await signedPageHandle("notion-key", "old-page-id"), previousGuide: validGuide, instruction: "make it shorter" },
      }),
      notionEnvironment,
    );

    const anthropicBody = JSON.parse(String(callsTo(fetchMock, "api.anthropic.com")[0][1]?.body));
    const [transcriptBlock, ...laterBlocks] = anthropicBody.messages[0].content;
    expect(transcriptBlock).toMatchObject({ cache_control: { type: "ephemeral" } });
    expect(transcriptBlock.text).toContain("[83] Fuel burns in the combustor.");
    const laterText = laterBlocks.map((block: { text: string }) => block.text).join("\n");
    expect(laterText).toContain("Focus: only the combustor");
    expect(laterText).toContain("missed at 83s: Where does fuel burn?");
    expect(laterText).toContain("make it shorter");
    expect(laterText).toContain('"title":"Jet engines"');
  });

  it("creates the new page, then trashes the replaced page on a revision", async () => {
    const fetchMock = stubFetch();

    const response = await handleStudyGuide(
      requestWithBody({
        ...validRequestBody,
        revision: { pageHandle: await signedPageHandle("notion-key", "old-page-id"), previousGuide: validGuide, instruction: "make it shorter" },
      }),
      notionEnvironment,
    );

    expect(response.status).toBe(200);
    const notionCalls = callsTo(fetchMock, "api.notion.com");
    expect(notionCalls.map(([url, init]) => `${init?.method} ${url}`)).toEqual([
      "POST https://api.notion.com/v1/pages",
      "PATCH https://api.notion.com/v1/pages/old-page-id",
    ]);
    expect(JSON.parse(String(notionCalls[1][1]?.body))).toEqual({ in_trash: true });
  });

  it("refreshes a revision with no instruction with no model call, keeping the guide and adding the quiz results", async () => {
    const fetchMock = stubFetch();
    const previousPageHandle = await signedPageHandle("notion-key", "old-page-id");

    const response = await handleStudyGuide(
      requestWithBody({ ...validRequestBody, revision: { pageHandle: previousPageHandle, previousGuide: validGuide } }),
      notionEnvironment,
    );

    expect(response.status).toBe(200);
    expect((await response.json()).guide).toEqual(validGuide);
    expect(callsTo(fetchMock, "api.anthropic.com")).toHaveLength(0);
    const notionCalls = callsTo(fetchMock, "api.notion.com");
    expect(notionCalls.map(([url, init]) => `${init?.method} ${String(url)}`)).toEqual([
      "POST https://api.notion.com/v1/pages",
      "PATCH https://api.notion.com/v1/pages/old-page-id",
    ]);
    expect(String(notionCalls[0]?.[1]?.body)).toContain("Review these first");
  });

  it("still answers 200 with the new page when trashing the old one fails", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    stubFetch({ trashStatus: 404 });

    const response = await handleStudyGuide(
      requestWithBody({
        ...validRequestBody,
        revision: { pageHandle: await signedPageHandle("notion-key", "old-page-id"), previousGuide: validGuide, instruction: "make it shorter" },
      }),
      notionEnvironment,
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ pageHandle: await signedPageHandle("notion-key", "new-page-id") });
  });

  it("answers 400 for a revision whose page handle this Worker did not sign, before any model or Notion call", async () => {
    const fetchMock = stubFetch();
    const handleSignedWithAnotherKey = await signedPageHandle("another-key", "someone-elses-page");

    for (const forgedPageHandle of ["someone-elses-page", "someone-elses-page.00", handleSignedWithAnotherKey]) {
      const response = await handleStudyGuide(
        requestWithBody({
          ...validRequestBody,
          revision: { pageHandle: forgedPageHandle, previousGuide: validGuide, instruction: "make it shorter" },
        }),
        notionEnvironment,
      );
      expect(response.status).toBe(400);
    }
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("answers 502 when Notion rejects the new page, and trashes nothing", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const fetchMock = stubFetch({ createStatus: 400 });

    const response = await handleStudyGuide(
      requestWithBody({
        ...validRequestBody,
        revision: { pageHandle: await signedPageHandle("notion-key", "old-page-id"), previousGuide: validGuide, instruction: "make it shorter" },
      }),
      notionEnvironment,
    );

    expect(response.status).toBe(502);
    expect(callsTo(fetchMock, "api.notion.com").map(([, init]) => init?.method)).toEqual(["POST"]);
  });

  it("asks the model again with the broken rule named when a guide is rejected", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const badGuide = { ...validGuide, sections: [{ heading: "Intro", points: [{ text: "Air.", seconds: 5 }] }] };
    const replies = [badGuide, validGuide];
    const fetchMock = vi.fn(async (url: string | URL | Request, _init?: RequestInit) => {
      if (String(url).startsWith("https://api.anthropic.com/")) {
        return new Response(JSON.stringify({ content: [{ type: "text", text: JSON.stringify(replies.shift()) }] }));
      }
      return new Response(JSON.stringify({ id: "new-page-id", url: "https://notion.so/new-page-id" }));
    });
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleStudyGuide(requestWithBody(validRequestBody), notionEnvironment);

    expect(response.status).toBe(200);
    const secondAnthropicBody = String(fetchMock.mock.calls[1]?.[1]?.body);
    expect(secondAnthropicBody).toContain("Your previous reply was rejected: seconds 5 is before the first transcript line at 10");
  });

  it("answers 502 when the model keeps breaking a rule through all 3 attempts, and writes no page", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const badGuide = { ...validGuide, sections: [] };
    const fetchMock = vi.fn(
      async (_url: string | URL | Request, _init?: RequestInit) =>
        new Response(JSON.stringify({ content: [{ type: "text", text: JSON.stringify(badGuide) }] })),
    );
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleStudyGuide(requestWithBody(validRequestBody), notionEnvironment);

    expect(response.status).toBe(502);
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });
});
