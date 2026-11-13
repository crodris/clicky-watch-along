import { afterEach, describe, expect, it, vi } from "vitest";
import { handleVoiceCommand, toolsForAnthropic, voiceCommandReply, type VoiceCommandTool } from "./voiceCommand";

const rotateTool: VoiceCommandTool = {
  name: "rotate_model",
  description: "Turns the model around its center.",
  inputSchema: {
    type: "object",
    properties: { yawDegrees: { type: "number" } },
    required: ["yawDegrees"],
  },
};

const sceneStateTool: VoiceCommandTool = {
  name: "get_scene_state",
  description: "Reads the camera and the focused part.",
  inputSchema: { type: "object", properties: {} },
  readOnly: true,
};

const validRequestBody = {
  messages: [{ role: "user", content: "turn it the other way" }],
  tools: [rotateTool, sceneStateTool],
};

function requestWithBody(body: unknown): Request {
  return new Request("https://worker.test/voice-command", { method: "POST", body: JSON.stringify(body) });
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("toolsForAnthropic", () => {
  it("requires a confirmation on a tool that changes the screen and leaves it optional on a read-only tool", () => {
    const [rotate, sceneState] = toolsForAnthropic([rotateTool, sceneStateTool]);

    expect(rotate).toMatchObject({
      name: "rotate_model",
      input_schema: {
        type: "object",
        properties: { yawDegrees: { type: "number" }, confirmation: { type: "string" } },
        required: ["yawDegrees", "confirmation"],
      },
    });
    expect(sceneState).toMatchObject({
      input_schema: { properties: { confirmation: { type: "string" } }, required: [] },
    });
  });

  it("does not change the tools it was given", () => {
    const before = JSON.stringify([rotateTool, sceneStateTool]);

    toolsForAnthropic([rotateTool, sceneStateTool]);

    expect(JSON.stringify([rotateTool, sceneStateTool])).toBe(before);
  });

  it("keeps a confirmation property the app's schema already has", () => {
    const appConfirmation = { type: "string", description: "The app's own words" };
    const [tool] = toolsForAnthropic([
      { ...rotateTool, inputSchema: { type: "object", properties: { confirmation: appConfirmation } } },
    ]);

    expect(tool).toMatchObject({ input_schema: { properties: { confirmation: appConfirmation } } });
  });

  it("puts the cache breakpoint on the last tool only", () => {
    const tools = toolsForAnthropic([rotateTool, sceneStateTool, { ...rotateTool, name: "zoom" }]);

    expect(tools.map((tool) => "cache_control" in tool)).toEqual([false, false, true]);
    expect(tools[2]).toMatchObject({ cache_control: { type: "ephemeral" } });
  });
});

describe("voiceCommandReply", () => {
  it("keeps text and tool_use blocks and drops thinking", () => {
    const reply = voiceCommandReply({
      content: [
        { type: "thinking", thinking: "hmm", signature: "x" },
        { type: "text", text: "Sure." },
        { type: "tool_use", id: "toolu_1", name: "rotate_model", input: { yawDegrees: -45, confirmation: "there" } },
      ],
      stop_reason: "tool_use",
      usage: { input_tokens: 10 },
    });

    expect(reply).toEqual({
      content: [
        { type: "text", text: "Sure." },
        { type: "tool_use", id: "toolu_1", name: "rotate_model", input: { yawDegrees: -45, confirmation: "there" } },
      ],
      stopReason: "tool_use",
    });
  });

  it("is undefined when the reply has no content list", () => {
    expect(voiceCommandReply({ stop_reason: "end_turn" })).toBeUndefined();
  });
});

describe("handleVoiceCommand", () => {
  it("sends Haiku the cached tools and system prompt and returns the tool calls", async () => {
    const toolCall = { type: "tool_use", id: "toolu_1", name: "rotate_model", input: { yawDegrees: -45, confirmation: "there" } };
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) =>
      new Response(JSON.stringify({ content: [toolCall], stop_reason: "tool_use" })),
    );
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleVoiceCommand(requestWithBody(validRequestBody), "key");

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ content: [toolCall], stopReason: "tool_use" });
    const sentBody: unknown = JSON.parse(String(fetchMock.mock.calls[0]?.[1].body));
    expect(sentBody).toMatchObject({
      model: "claude-haiku-5-5",
      max_tokens: 1024,
      thinking: { type: "disabled" },
      output_config: { effort: "low" },
      tool_choice: { type: "auto" },
      system: [{ type: "text", cache_control: { type: "ephemeral" } }],
      messages: validRequestBody.messages,
      tools: [{ name: "rotate_model" }, { name: "get_scene_state", cache_control: { type: "ephemeral" } }],
    });
  });

  it("logs the token usage under the route name", async () => {
    const consoleLogSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify({ content: [], usage: { input_tokens: 900, output_tokens: 40 } }))),
    );

    await handleVoiceCommand(requestWithBody(validRequestBody), "key");

    expect(consoleLogSpy).toHaveBeenCalledWith('[/voice-command] usage {"input_tokens":900,"output_tokens":40}');
  });

  it("passes an upstream error status through", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    vi.stubGlobal("fetch", vi.fn(async () => new Response("overloaded", { status: 529 })));

    const response = await handleVoiceCommand(requestWithBody(validRequestBody), "key");

    expect(response.status).toBe(529);
  });

  it("returns 502 when the upstream reply has no content list", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify({ stop_reason: "end_turn" }))));

    const response = await handleVoiceCommand(requestWithBody(validRequestBody), "key");

    expect(response.status).toBe(502);
  });

  it.each([
    ["a tool name with capitals", { tools: [{ ...rotateTool, name: "RotateModel" }] }],
    ["duplicate tool names", { tools: [rotateTool, rotateTool] }],
    ["an inputSchema that is not an object schema", { tools: [{ ...rotateTool, inputSchema: { type: "string" } }] }],
    ["no tools", { tools: [] }],
    ["a last message that is not from the user", { messages: [{ role: "user", content: "hi" }, { role: "assistant", content: "hello" }] }],
    ["a first message that is not from the user", { messages: [{ role: "assistant", content: "hello" }, { role: "user", content: "hi" }] }],
    ["more than 20 messages", { messages: Array.from({ length: 21 }, () => ({ role: "user", content: "hi" })) }],
  ])("rejects %s with 400 and never calls Anthropic", async (_name, override) => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleVoiceCommand(requestWithBody({ ...validRequestBody, ...override }), "key");

    expect(response.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("accepts tool_use and tool_result blocks in the message history", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify({ content: [{ type: "text", text: "Done." }], stop_reason: "end_turn" }))),
    );
    const messages = [
      { role: "user", content: "turn it" },
      { role: "assistant", content: [{ type: "tool_use", id: "toolu_1", name: "rotate_model", input: { yawDegrees: 45, confirmation: "there" } }] },
      { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_1", content: "ok" }] },
    ];

    const response = await handleVoiceCommand(requestWithBody({ ...validRequestBody, messages }), "key");

    expect(response.status).toBe(200);
  });
});
