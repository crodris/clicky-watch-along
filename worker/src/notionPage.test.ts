import { afterEach, describe, expect, it, vi } from "vitest";
import { handleBackgroundAgent, handleNotionPage, notionPageBlocks } from "./backgroundAgent";

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

const turnRequest = {
  messages: [{ role: "user", content: "Task from the learner: compare the two catches" }],
  tools: [{ name: "finish", description: "End the task.", inputSchema: { type: "object", properties: { spokenSummary: { type: "string" } } } }],
};

function requestWithBody(body: unknown): Request {
  return new Request("http://local/background-agent", { method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json" } });
}

describe("handleBackgroundAgent", () => {
  it("sends the web tools with the app's tools and returns every block of the reply", async () => {
    const replyContent = [
      { type: "thinking", thinking: "", signature: "abc" },
      { type: "server_tool_use", id: "s1", name: "web_search", input: { query: "booster catch" } },
      { type: "web_search_tool_result", tool_use_id: "s1", content: [] },
      { type: "tool_use", id: "t1", name: "finish", input: { spokenSummary: "It was caught." } },
    ];
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) =>
      new Response(JSON.stringify({ content: replyContent, stop_reason: "tool_use", usage: {} }), { status: 200 }),
    );
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleBackgroundAgent(requestWithBody(turnRequest), "anthropic-key");

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ content: replyContent, stopReason: "tool_use" });
    const sentBody = JSON.parse(String(fetchMock.mock.calls[0]?.[1].body));
    expect(sentBody.tools.map((tool: { name: string }) => tool.name)).toEqual(["web_search", "web_fetch", "finish"]);
    expect(sentBody.tools[2]).toMatchObject({ input_schema: turnRequest.tools[0]?.inputSchema, strict: true, cache_control: { type: "ephemeral" } });
  });

  it("refuses a history that does not start with the learner's message, without calling a model", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleBackgroundAgent(requestWithBody({ ...turnRequest, messages: [{ role: "assistant", content: "hi" }] }), "anthropic-key");

    expect(response.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe("notionPageBlocks", () => {
  it("puts the summary first, then each section, then the sources as links", () => {
    const blocks = notionPageBlocks({
      title: "Ship catch and booster catch",
      summary: "The ship was caught after orbit.",
      sections: [{ heading: "Ship catch", points: ["Flight 15", "Tower arms"] }],
      sources: [{ title: "SpaceX", url: "https://www.spacex.com/launches" }],
    });

    expect(blocks.map((block) => block.type)).toEqual(["paragraph", "heading_2", "bulleted_list_item", "bulleted_list_item", "heading_2", "bulleted_list_item"]);
    expect(JSON.stringify(blocks[5])).toContain('"url":"https://www.spacex.com/launches"');
  });
});

describe("handleNotionPage", () => {
  const smallPage = { title: "Ship catch", summary: "The ship was caught.", sections: [], sources: [] };

  function notionPageRequest(body: unknown): Request {
    return new Request("http://local/notion-page", { method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json" } });
  }

  it("logs a Notion failure under /notion-page, not /study-guide, and answers 502", async () => {
    const errorLog = vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.stubGlobal("fetch", vi.fn(async () => new Response("{}", { status: 500 })));

    const response = await handleNotionPage(notionPageRequest(smallPage), "notion-key");

    expect(response.status).toBe(502);
    expect(errorLog.mock.calls[0]?.[0]).toMatch(/^\[\/notion-page\] Notion API error 500 on POST \/pages/);
  });

  function pageWith(options: { sectionCount: number; pointsPerSection: number; sourceCount: number }) {
    return {
      title: "Ship catch",
      summary: "The ship was caught.",
      sections: Array.from({ length: options.sectionCount }, (_, sectionIndex) => ({
        heading: `Section ${sectionIndex}`,
        points: Array.from({ length: options.pointsPerSection }, (_, pointIndex) => `Point ${pointIndex}`),
      })),
      sources: Array.from({ length: options.sourceCount }, (_, sourceIndex) => ({ title: `Source ${sourceIndex}`, url: `https://example.com/${sourceIndex}` })),
    };
  }

  function stubNotionCreate() {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => new Response(JSON.stringify({ id: "page-id", url: "https://notion.so/page-id" })));
    vi.stubGlobal("fetch", fetchMock);
    return fetchMock;
  }

  it("writes the largest allowed page in exactly 100 blocks, Notion's limit on children in one request", async () => {
    const fetchMock = stubNotionCreate();

    const response = await handleNotionPage(notionPageRequest(pageWith({ sectionCount: 8, pointsPerSection: 10, sourceCount: 10 })), "notion-key");

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ pageURL: "https://notion.so/page-id" });
    const sentBody = JSON.parse(String(fetchMock.mock.calls[0]?.[1].body));
    expect(sentBody.children).toHaveLength(100);
  });

  it.each([
    ["a ninth section", { sectionCount: 9, pointsPerSection: 1, sourceCount: 0 }],
    ["an eleventh point in a section", { sectionCount: 1, pointsPerSection: 11, sourceCount: 0 }],
    ["an eleventh source", { sectionCount: 0, pointsPerSection: 1, sourceCount: 11 }],
  ])("answers 400 for %s, so a page never passes 100 blocks", async (_name, size) => {
    const fetchMock = stubNotionCreate();

    const response = await handleNotionPage(notionPageRequest(pageWith(size)), "notion-key");

    expect(response.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it.each([undefined, ""])("answers 503 without calling Notion when NOTION_API_KEY is %j", async (missingNotionKey) => {
    const fetchMock = stubNotionCreate();

    const response = await handleNotionPage(notionPageRequest(smallPage), missingNotionKey);

    expect(response.status).toBe(503);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("answers 400 for a source that is not https, without calling Notion", async () => {
    const fetchMock = stubNotionCreate();

    const response = await handleNotionPage(
      notionPageRequest({ ...smallPage, sources: [{ title: "Plain http", url: "http://example.com/page" }] }),
      "notion-key",
    );

    expect(response.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
