import { afterEach, describe, expect, it, vi } from "vitest";
import { handleBackgroundAgent, notionPageBlocks } from "./backgroundAgent";

afterEach(() => {
  vi.unstubAllGlobals();
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
