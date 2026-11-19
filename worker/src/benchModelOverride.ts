/**
 * A local benchmark override that runs the model routes on another model, for bench/bench.ts bakeoffs.
 *
 * It does nothing unless the Worker is started with --var BENCH_MODEL:<model>, so the deployed Worker and the app's
 * Worker on port 8787 never use it, and wrangler.toml never sets it. Each Worker process holds one override for its whole
 * life, so a bakeoff starts one Worker per model, each on its own port.
 *
 *   BENCH_MODEL         claude-* swaps the model of every call that goes through requestAnthropicMessage and of /chat.
 *                       gpt-* sends those calls to OpenAI's Responses API instead, in the shape the route already reads.
 *                       gemini-* sends them to Google's OpenAI-compatible Chat Completions endpoint, with GEMINI_API_KEY.
 *   BENCH_EFFORT        Replaces the route's own effort. Claude: low, medium, high, xhigh, or max.
 *                       GPT: none, minimal, low, medium, high, or xhigh.
 *                       Gemini: minimal (sent as low), low, medium, high, or xhigh.
 *   BENCH_SERVICE_TIER  GPT only, such as ultrafast. The tier OpenAI reports back goes in the usage log line.
 *
 * /v1/messages (the agent harness) takes only a claude-* model and answers a 501 to any other. On /live-scene a gpt-* model
 * runs the app's own GPT request with its model and tier swapped, and any other model runs the Claude request (liveScene.ts).
 * /video-quiz-plan runs on GPT-6.2 Sol in every Worker through the same OpenAI mapping, and BENCH_MODEL replaces it.
 * Every prompt here was tuned for Claude, so a GPT or Gemini model that loses may only have lost to the prompt.
 */

import { z } from "zod";

const claudeEfforts = ["low", "medium", "high", "xhigh", "max"];
const gptEfforts = ["none", "minimal", "low", "medium", "high", "xhigh"];
const geminiEfforts = ["minimal", "low", "medium", "high", "xhigh"];
const serviceTierPattern = /^[a-z_]+$/;

/**
 * The efforts a GPT model gets for a route that turns thinking off, lowest first. Which of them a model accepts is
 * not listed anywhere the Worker can read, so a 400 that names the effort moves to the next one.
 */
const thinkingOffEffortLadder = ["none", "minimal", "low"];

export type ClaudeBenchOverride = { provider: "anthropic"; model: string; effort?: string };
export type OpenAIBenchOverride = { provider: "openai"; model: string; apiKey: string; effort?: string; serviceTier?: string };
export type GeminiBenchOverride = { provider: "gemini"; model: string; apiKey: string; effort?: string };
export type BenchModelOverride = ClaudeBenchOverride | OpenAIBenchOverride | GeminiBenchOverride;

let activeOverride: BenchModelOverride | undefined;

/** The lowest effort each GPT model accepted for a route with thinking off, so later calls skip the 400s. */
const acceptedThinkingOffEffortByModel = new Map<string, string>();

/**
 * Called at the top of every request. Returns a message when the vars are wrong, which the Worker answers as a 500,
 * and undefined otherwise. With no BENCH_MODEL it clears the override, and BENCH_EFFORT and BENCH_SERVICE_TIER alone do nothing.
 */
export function configureBenchModelOverride(env: {
  BENCH_MODEL?: string;
  BENCH_EFFORT?: string;
  BENCH_SERVICE_TIER?: string;
  OPENAI_API_KEY?: string;
  GEMINI_API_KEY?: string;
}): string | undefined {
  activeOverride = undefined;
  const model = env.BENCH_MODEL?.trim();
  if (model === undefined || model === "") {
    return undefined;
  }
  const effort = env.BENCH_EFFORT?.trim() || undefined;
  const serviceTier = env.BENCH_SERVICE_TIER?.trim() || undefined;

  if (model.startsWith("claude-")) {
    if (effort !== undefined && !claudeEfforts.includes(effort)) {
      return `BENCH_EFFORT for a Claude model must be ${claudeEfforts.join(", ")}, not ${effort}`;
    }
    if (serviceTier !== undefined) {
      return "BENCH_SERVICE_TIER applies only to a gpt-* BENCH_MODEL";
    }
    activeOverride = { provider: "anthropic", model, effort };
    return undefined;
  }

  if (model.startsWith("gpt-")) {
    if (effort !== undefined && !gptEfforts.includes(effort)) {
      return `BENCH_EFFORT for a GPT model must be ${gptEfforts.join(", ")}, not ${effort}`;
    }
    if (serviceTier !== undefined && !serviceTierPattern.test(serviceTier)) {
      return `BENCH_SERVICE_TIER must be lowercase letters, such as ultrafast, not ${serviceTier}`;
    }
    const apiKey = env.OPENAI_API_KEY?.trim();
    if (apiKey === undefined || apiKey === "") {
      return "A gpt-* BENCH_MODEL needs OPENAI_API_KEY";
    }
    activeOverride = { provider: "openai", model, apiKey, effort, serviceTier };
    return undefined;
  }

  if (model.startsWith("gemini-")) {
    if (effort !== undefined && !geminiEfforts.includes(effort)) {
      return `BENCH_EFFORT for a Gemini model must be ${geminiEfforts.join(", ")}, not ${effort}`;
    }
    // Gemini has no service tiers in this bench, and a tier left set would silently not apply.
    if (serviceTier !== undefined) {
      return "BENCH_SERVICE_TIER applies only to a gpt-* BENCH_MODEL";
    }
    const apiKey = env.GEMINI_API_KEY?.trim();
    if (apiKey === undefined || apiKey === "") {
      return "A gemini-* BENCH_MODEL needs GEMINI_API_KEY";
    }
    activeOverride = { provider: "gemini", model, apiKey, effort };
    return undefined;
  }

  return `BENCH_MODEL must start with claude-, gpt-, or gemini-, not ${model}`;
}

export function benchModelOverride(): BenchModelOverride | undefined {
  return activeOverride;
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Only Haiku 5.5 takes thinking off. Sonnet 5.5, Opus 5.5, and Fable 5.2 answer a 400 to `thinking: disabled`. */
const claudeModelsThatTurnThinkingOff = ["claude-haiku-5-5"];

/**
 * The Claude override: the same request with its model replaced, and its effort when BENCH_EFFORT is set.
 * A route that turns thinking off (/voice-command) keeps its low effort and loses the `thinking` field on a model
 * that cannot turn thinking off, which is as close to thinking off as that model goes.
 */
export function applyClaudeBenchOverride(messagesRequestBody: unknown, override: ClaudeBenchOverride): unknown {
  if (!isPlainRecord(messagesRequestBody)) {
    return messagesRequestBody;
  }
  const outputConfig = isPlainRecord(messagesRequestBody.output_config) ? messagesRequestBody.output_config : {};
  const { thinking, ...requestWithoutThinking } = messagesRequestBody;
  const thinkingIsDisabled = isPlainRecord(thinking) && thinking.type === "disabled";
  const keepsThinkingField = !thinkingIsDisabled || claudeModelsThatTurnThinkingOff.includes(override.model);
  return {
    ...(keepsThinkingField ? messagesRequestBody : requestWithoutThinking),
    model: override.model,
    ...(override.effort === undefined ? {} : { output_config: { ...outputConfig, effort: override.effort } }),
  };
}

// ---------- Anthropic Messages request to OpenAI Responses request ----------

const textSystemBlockSchema = z.object({ type: z.literal("text"), text: z.string() }).passthrough();

const anthropicRequestSchema = z
  .object({
    system: z.union([z.string(), z.array(textSystemBlockSchema)]).optional(),
    messages: z.array(
      z.object({
        role: z.enum(["user", "assistant"]),
        content: z.union([z.string(), z.array(z.record(z.unknown()))]),
      }),
    ),
    max_tokens: z.number().optional(),
    thinking: z.object({ type: z.string() }).passthrough().optional(),
    output_config: z
      .object({
        effort: z.string().optional(),
        format: z.object({ type: z.literal("json_schema"), schema: z.record(z.unknown()) }).passthrough().optional(),
      })
      .passthrough()
      .optional(),
    tools: z
      .array(
        z.object({ name: z.string(), description: z.string().optional(), input_schema: z.record(z.unknown()) }).passthrough(),
      )
      .optional(),
    tool_choice: z.object({ type: z.string() }).passthrough().optional(),
  })
  .passthrough();

const imageSourceSchema = z.object({ type: z.literal("base64"), media_type: z.string(), data: z.string() });

export type BenchRequestMapping = { ok: true; body: Record<string, unknown> } | { ok: false; unsupported: string };

function openAIContentPart(role: "user" | "assistant", block: Record<string, unknown>): Record<string, unknown> | string {
  if (block.type === "text" && typeof block.text === "string") {
    return { type: role === "user" ? "input_text" : "output_text", text: block.text };
  }
  if (block.type === "image" && role === "user") {
    const imageURL = base64ImageDataURL(block);
    return imageURL === undefined ? "an image that is not base64" : { type: "input_image", image_url: imageURL, detail: "high" };
  }
  return `a ${String(block.type)} block`;
}

/** The effort GPT or Gemini gets: BENCH_EFFORT first, then the lowest effort for thinking off, then the route's own effort. */
function reasoningEffortFor(
  request: z.infer<typeof anthropicRequestSchema>,
  override: { effort?: string },
  thinkingOffEffort: string,
): string | undefined {
  if (override.effort !== undefined) {
    return override.effort;
  }
  if (request.thinking?.type === "disabled") {
    return thinkingOffEffort;
  }
  const routeEffort = request.output_config?.effort;
  // Claude's top effort is called xhigh by OpenAI and Gemini, which have no max.
  return routeEffort === "max" ? "xhigh" : routeEffort;
}

/**
 * Maps one Anthropic Messages request to an OpenAI Responses request. A shape no benchmark case sends, such as
 * tool_result blocks, a forced tool, or a server tool, is reported as unsupported instead of being guessed at.
 */
export function anthropicBodyToOpenAIResponsesBody(
  anthropicBody: unknown,
  override: OpenAIBenchOverride,
  thinkingOffEffort: string = thinkingOffEffortLadder[0],
): BenchRequestMapping {
  const parsedRequest = anthropicRequestSchema.safeParse(anthropicBody);
  if (!parsedRequest.success) {
    const firstIssue = parsedRequest.error.issues[0];
    return { ok: false, unsupported: `a request the port cannot read (${firstIssue?.path.join(".")}: ${firstIssue?.message})` };
  }
  const request = parsedRequest.data;

  if (request.tool_choice !== undefined && request.tool_choice.type !== "auto") {
    return { ok: false, unsupported: `tool_choice ${request.tool_choice.type}` };
  }

  const input: Array<Record<string, unknown>> = [];
  for (const message of request.messages) {
    const blocks = typeof message.content === "string" ? [{ type: "text", text: message.content }] : message.content;
    const content: Array<Record<string, unknown>> = [];
    for (const block of blocks) {
      const part = openAIContentPart(message.role, block);
      if (typeof part === "string") {
        return { ok: false, unsupported: part };
      }
      content.push(part);
    }
    input.push({ role: message.role, content });
  }

  const instructions =
    typeof request.system === "string" ? request.system : request.system?.map((systemBlock) => systemBlock.text).join("\n\n");
  const reasoningEffort = reasoningEffortFor(request, override, thinkingOffEffort);
  const responseFormat = request.output_config?.format;

  return {
    ok: true,
    body: {
      model: override.model,
      ...(instructions === undefined || instructions === "" ? {} : { instructions }),
      input,
      // Both vendors count reasoning toward this limit.
      ...(request.max_tokens === undefined ? {} : { max_output_tokens: request.max_tokens }),
      ...(reasoningEffort === undefined ? {} : { reasoning: { effort: reasoningEffort } }),
      ...(responseFormat === undefined
        ? {}
        : { text: { format: { type: "json_schema", name: "reply", schema: responseFormat.schema, strict: true } } }),
      // The app's tool schemas have optional properties, which strict mode refuses.
      ...(request.tools === undefined
        ? {}
        : {
            tools: request.tools.map((tool) => ({
              type: "function",
              name: tool.name,
              description: tool.description ?? "",
              parameters: tool.input_schema,
              strict: false,
            })),
            tool_choice: "auto",
          }),
      ...(override.serviceTier === undefined ? {} : { service_tier: override.serviceTier }),
    },
  };
}

// ---------- OpenAI Responses reply to Anthropic Messages reply ----------

const openAIOutputItemSchema = z.object({ type: z.string() }).passthrough();

const openAIResponseSchema = z
  .object({
    id: z.string().optional(),
    model: z.string().optional(),
    status: z.string().optional(),
    error: z.object({ message: z.string().optional() }).nullish(),
    incomplete_details: z.object({ reason: z.string().optional() }).nullish(),
    output: z.array(openAIOutputItemSchema),
    usage: z.record(z.unknown()).nullish(),
    service_tier: z.string().nullish(),
  })
  .passthrough();

const openAIMessageItemSchema = z.object({
  content: z.array(z.object({ type: z.string(), text: z.string().optional(), refusal: z.string().optional() })),
});

const openAIFunctionCallItemSchema = z.object({
  id: z.string().optional(),
  call_id: z.string().optional(),
  name: z.string(),
  arguments: z.string(),
});

export type AnthropicShapedMessage = {
  id: string | undefined;
  type: "message";
  role: "assistant";
  model: string | undefined;
  content: Array<
    { type: "text"; text: string } | { type: "tool_use"; id: string; name: string; input: Record<string, unknown> }
  >;
  stop_reason: "end_turn" | "tool_use" | "max_tokens" | "refusal";
  usage: { input_tokens: number; output_tokens: number };
};

export type OpenAIReplyMapping = { ok: true; message: AnthropicShapedMessage } | { ok: false; error: string };

function numberOrZero(value: unknown): number {
  return typeof value === "number" ? value : 0;
}

export function openAIResponseToAnthropicMessage(responseJSON: unknown): OpenAIReplyMapping {
  const parsedResponse = openAIResponseSchema.safeParse(responseJSON);
  if (!parsedResponse.success) {
    return { ok: false, error: "OpenAI response had no output list" };
  }
  const response = parsedResponse.data;
  if (response.status === "failed") {
    return { ok: false, error: response.error?.message ?? "OpenAI response failed" };
  }

  const content: AnthropicShapedMessage["content"] = [];
  let refused = false;
  for (const outputItem of response.output) {
    if (outputItem.type === "message") {
      const messageItem = openAIMessageItemSchema.safeParse(outputItem);
      for (const contentPart of messageItem.success ? messageItem.data.content : []) {
        if (contentPart.type === "output_text" && contentPart.text !== undefined) {
          content.push({ type: "text", text: contentPart.text });
        } else if (contentPart.type === "refusal" && contentPart.refusal !== undefined) {
          refused = true;
          content.push({ type: "text", text: contentPart.refusal });
        }
      }
    } else if (outputItem.type === "function_call") {
      const functionCall = openAIFunctionCallItemSchema.safeParse(outputItem);
      if (!functionCall.success) {
        return { ok: false, error: "OpenAI function_call had no name or arguments" };
      }
      content.push({
        type: "tool_use",
        id: functionCall.data.call_id ?? functionCall.data.id ?? "",
        name: functionCall.data.name,
        input: parseToolArguments(functionCall.data.arguments),
      });
    }
    // Reasoning items carry no answer, so they are dropped, as Anthropic's thinking blocks are by the routes.
  }

  const incompleteReason = response.incomplete_details?.reason;
  const stopReason: AnthropicShapedMessage["stop_reason"] = content.some((block) => block.type === "tool_use")
    ? "tool_use"
    : incompleteReason === "max_output_tokens"
      ? "max_tokens"
      : refused || incompleteReason === "content_filter"
        ? "refusal"
        : "end_turn";

  return {
    ok: true,
    message: {
      id: response.id,
      type: "message",
      role: "assistant",
      model: response.model,
      content,
      stop_reason: stopReason,
      usage: { input_tokens: numberOrZero(response.usage?.input_tokens), output_tokens: numberOrZero(response.usage?.output_tokens) },
    },
  };
}

/** Arguments from a function with strict off can be invalid JSON. That reaches the route as an empty input, which its check rejects. */
function parseToolArguments(argumentsText: string): Record<string, unknown> {
  try {
    const parsedArguments: unknown = JSON.parse(argumentsText);
    if (isPlainRecord(parsedArguments)) {
      return parsedArguments;
    }
  } catch {
    // Falls through to the empty input below.
  }
  console.error(`[bench] A function call's arguments were not a JSON object: ${argumentsText.slice(0, 200)}`);
  return {};
}

// ---------- Calling OpenAI ----------

function postToOpenAIResponses(override: OpenAIBenchOverride, responsesBody: Record<string, unknown>): Promise<Response> {
  return fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { authorization: `Bearer ${override.apiKey}`, "content-type": "application/json" },
    body: JSON.stringify(responsesBody),
  });
}

function thinkingIsOff(anthropicBody: unknown): boolean {
  return isPlainRecord(anthropicBody) && isPlainRecord(anthropicBody.thinking) && anthropicBody.thinking.type === "disabled";
}

export type BenchMessageResult =
  | {
      ok: true;
      message: AnthropicShapedMessage;
      /**
       * The reply logModelUsage reads: its usage fields, which the benchmark prices, and the tier it used.
       * OpenAI's own reply, or for Gemini a reply rebuilt in the same field names (see geminiUsageForLog).
       */
      responseJSON: unknown;
    }
  | { ok: false; status: number; error: string };

/** One non-streaming call for requestAnthropicMessage: the Anthropic request in, an Anthropic-shaped message out. */
export async function requestBenchOpenAIMessage(
  override: OpenAIBenchOverride,
  routeName: string,
  anthropicBody: unknown,
): Promise<BenchMessageResult> {
  // A route with thinking off and no BENCH_EFFORT starts at the lowest effort this model has accepted before.
  const searchesForLowestEffort = thinkingIsOff(anthropicBody) && override.effort === undefined;
  const effortLadder = searchesForLowestEffort
    ? thinkingOffEffortLadder.slice(Math.max(0, thinkingOffEffortLadder.indexOf(acceptedThinkingOffEffortByModel.get(override.model) ?? "")))
    : [thinkingOffEffortLadder[0]];

  let upstreamResponse: Response | undefined;
  for (const [ladderIndex, thinkingOffEffort] of effortLadder.entries()) {
    const mapping = anthropicBodyToOpenAIResponsesBody(anthropicBody, override, thinkingOffEffort);
    if (!mapping.ok) {
      return { ok: false, status: 501, error: `BENCH_MODEL ${override.model} cannot take ${mapping.unsupported}` };
    }
    try {
      upstreamResponse = await postToOpenAIResponses(override, mapping.body);
    } catch (error) {
      console.error(`[${routeName}] OpenAI request failed:`, error);
      return { ok: false, status: 502, error: "OpenAI could not be reached" };
    }
    if (upstreamResponse.ok) {
      if (searchesForLowestEffort) {
        acceptedThinkingOffEffortByModel.set(override.model, thinkingOffEffort);
      }
      break;
    }
    const errorText = await upstreamResponse.text();
    const triedEveryEffort = ladderIndex === effortLadder.length - 1;
    if (upstreamResponse.status === 400 && /effort|reasoning/i.test(errorText) && !triedEveryEffort) {
      continue;
    }
    console.error(`[${routeName}] OpenAI API error ${upstreamResponse.status}: ${errorText}`);
    return { ok: false, status: upstreamResponse.status, error: errorText.length > 0 ? errorText : "OpenAI request failed" };
  }
  if (upstreamResponse === undefined) {
    return { ok: false, status: 502, error: "OpenAI could not be reached" };
  }

  let responseJSON: unknown;
  try {
    responseJSON = await upstreamResponse.json();
  } catch {
    return { ok: false, status: 502, error: "OpenAI returned a body that was not JSON" };
  }
  const reply = openAIResponseToAnthropicMessage(responseJSON);
  if (!reply.ok) {
    return { ok: false, status: 502, error: reply.error };
  }
  return { ok: true, message: reply.message, responseJSON };
}

// ---------- Gemini: Anthropic Messages request to Chat Completions request, and the reply back ----------

/**
 * Gemini's OpenAI-compatible endpoint takes the Chat Completions shape, not Responses.
 * Thinking cannot be turned off there, so a route that turns it off gets the lowest effort.
 */
const geminiThinkingOffEffort = "low";

/**
 * The thought signature Gemini attaches to a tool call (`extra_content`), by the id the route and the app see.
 * The route's reply keeps only id, name, and input, and Gemini may refuse a later turn whose history lacks the
 * signature, so it is put back on the same call when the app sends that call in /voice-command's next turn.
 * One Worker process runs one bakeoff, so a map that never shrinks is fine.
 */
const geminiExtraContentByToolCallId = new Map<string, unknown>();
let geminiToolCallIdCounter = 0;

function base64ImageDataURL(imageBlock: Record<string, unknown>): string | undefined {
  const imageSource = imageSourceSchema.safeParse(imageBlock.source);
  return imageSource.success ? `data:${imageSource.data.media_type};base64,${imageSource.data.data}` : undefined;
}

/** A tool_result's content is a string or a list of text blocks. Anything else, such as an image, is not ported. */
function toolResultText(toolResultContent: unknown): string | undefined {
  if (toolResultContent === undefined) {
    return "";
  }
  if (typeof toolResultContent === "string") {
    return toolResultContent;
  }
  if (Array.isArray(toolResultContent)) {
    const texts: string[] = [];
    for (const contentBlock of toolResultContent) {
      if (!isPlainRecord(contentBlock) || contentBlock.type !== "text" || typeof contentBlock.text !== "string") {
        return undefined;
      }
      texts.push(contentBlock.text);
    }
    return texts.join("\n");
  }
  return undefined;
}

/**
 * The Chat Completions messages for an Anthropic request's history. A tool_use block in an assistant message becomes a
 * tool call on it, and a tool_result block in a user message becomes a `tool` message, placed before that user message's
 * other content so each tool message directly follows the call it answers.
 */
function geminiChatMessages(
  request: z.infer<typeof anthropicRequestSchema>,
): { ok: true; messages: Array<Record<string, unknown>> } | { ok: false; unsupported: string } {
  const messages: Array<Record<string, unknown>> = [];
  const system = typeof request.system === "string" ? request.system : request.system?.map((systemBlock) => systemBlock.text).join("\n\n");
  if (system !== undefined && system !== "") {
    messages.push({ role: "system", content: system });
  }

  const toolNamesByCallId = new Map<string, string>();
  for (const message of request.messages) {
    const blocks = typeof message.content === "string" ? [{ type: "text", text: message.content }] : message.content;

    if (message.role === "assistant") {
      const texts: string[] = [];
      const toolCalls: Array<Record<string, unknown>> = [];
      for (const block of blocks) {
        if (block.type === "text" && typeof block.text === "string") {
          texts.push(block.text);
        } else if (block.type === "tool_use" && typeof block.id === "string" && typeof block.name === "string") {
          toolNamesByCallId.set(block.id, block.name);
          const extraContent = geminiExtraContentByToolCallId.get(block.id);
          toolCalls.push({
            id: block.id,
            type: "function",
            function: { name: block.name, arguments: JSON.stringify(block.input ?? {}) },
            ...(extraContent === undefined ? {} : { extra_content: extraContent }),
          });
        } else {
          return { ok: false, unsupported: `a ${String(block.type)} block` };
        }
      }
      const text = texts.join("\n");
      messages.push({
        role: "assistant",
        // A message with tool calls may leave its content out.
        ...(text === "" && toolCalls.length > 0 ? {} : { content: text }),
        ...(toolCalls.length === 0 ? {} : { tool_calls: toolCalls }),
      });
      continue;
    }

    const toolMessages: Array<Record<string, unknown>> = [];
    const userParts: Array<Record<string, unknown>> = [];
    for (const block of blocks) {
      if (block.type === "text" && typeof block.text === "string") {
        userParts.push({ type: "text", text: block.text });
      } else if (block.type === "image") {
        const imageURL = base64ImageDataURL(block);
        if (imageURL === undefined) {
          return { ok: false, unsupported: "an image that is not base64" };
        }
        userParts.push({ type: "image_url", image_url: { url: imageURL } });
      } else if (block.type === "tool_result" && typeof block.tool_use_id === "string") {
        const resultText = toolResultText(block.content);
        if (resultText === undefined) {
          return { ok: false, unsupported: "a tool_result with a block that is not text" };
        }
        const toolName = toolNamesByCallId.get(block.tool_use_id);
        toolMessages.push({
          role: "tool",
          tool_call_id: block.tool_use_id,
          ...(toolName === undefined ? {} : { name: toolName }),
          content: resultText,
        });
      } else {
        return { ok: false, unsupported: `a ${String(block.type)} block` };
      }
    }
    messages.push(...toolMessages);
    if (userParts.length > 0) {
      messages.push({ role: "user", content: userParts });
    }
  }
  return { ok: true, messages };
}

/** Maps one Anthropic Messages request to a Gemini Chat Completions request, or says which shape it cannot port. */
export function anthropicBodyToGeminiChatBody(anthropicBody: unknown, override: GeminiBenchOverride): BenchRequestMapping {
  const parsedRequest = anthropicRequestSchema.safeParse(anthropicBody);
  if (!parsedRequest.success) {
    const firstIssue = parsedRequest.error.issues[0];
    return { ok: false, unsupported: `a request the port cannot read (${firstIssue?.path.join(".")}: ${firstIssue?.message})` };
  }
  const request = parsedRequest.data;

  if (request.tool_choice !== undefined && request.tool_choice.type !== "auto") {
    return { ok: false, unsupported: `tool_choice ${request.tool_choice.type}` };
  }
  const chatMessages = geminiChatMessages(request);
  if (!chatMessages.ok) {
    return chatMessages;
  }

  const reasoningEffort = reasoningEffortFor(request, override, geminiThinkingOffEffort);
  const responseFormat = request.output_config?.format;
  return {
    ok: true,
    body: {
      model: override.model,
      messages: chatMessages.messages,
      // Gemini counts its thinking toward this limit, as Claude and GPT do.
      ...(request.max_tokens === undefined ? {} : { max_tokens: request.max_tokens }),
      // Gemini has no minimal effort, so it is sent as low.
      ...(reasoningEffort === undefined ? {} : { reasoning_effort: reasoningEffort === "minimal" ? "low" : reasoningEffort }),
      ...(responseFormat === undefined
        ? {}
        : { response_format: { type: "json_schema", json_schema: { name: "reply", schema: responseFormat.schema, strict: true } } }),
      ...(request.tools === undefined
        ? {}
        : {
            tools: request.tools.map((tool) => ({
              type: "function",
              function: { name: tool.name, description: tool.description ?? "", parameters: tool.input_schema },
            })),
            tool_choice: "auto",
          }),
    },
  };
}

const geminiToolCallSchema = z
  .object({
    id: z.string().nullish(),
    function: z.object({ name: z.string(), arguments: z.string() }),
    extra_content: z.unknown().optional(),
  })
  .passthrough();

const geminiChatCompletionSchema = z
  .object({
    id: z.string().optional(),
    model: z.string().optional(),
    choices: z.array(
      z
        .object({
          message: z
            .object({
              content: z.string().nullish(),
              refusal: z.string().nullish(),
              tool_calls: z.array(z.unknown()).nullish(),
            })
            .passthrough(),
          finish_reason: z.string().nullish(),
        })
        .passthrough(),
    ),
    usage: z.record(z.unknown()).nullish(),
  })
  .passthrough();

/** The Anthropic stop reason for a Chat Completions finish reason, which says nothing of tool use when it is "stop". */
function anthropicStopReasonForFinishReason(finishReason: string, hasToolUse: boolean): AnthropicShapedMessage["stop_reason"] {
  if (hasToolUse || finishReason === "tool_calls") {
    return "tool_use";
  }
  if (finishReason === "length") {
    return "max_tokens";
  }
  return finishReason === "content_filter" ? "refusal" : "end_turn";
}

/**
 * Gemini's usage in the field names bench/usage.ts already reads from an OpenAI reply, so the Worker's usage log line
 * needs no second format. Gemini counts the cached tokens inside prompt_tokens, as OpenAI does. Its completion_tokens
 * may leave thinking out while total_tokens includes it, and thinking is billed as output, so the larger of the two
 * output counts is used.
 */
export function geminiUsageForLog(usage: unknown): Record<string, unknown> {
  const usageRecord = isPlainRecord(usage) ? usage : {};
  const promptTokens = numberOrZero(usageRecord.prompt_tokens);
  const completionTokens = numberOrZero(usageRecord.completion_tokens);
  const outputTokens = typeof usageRecord.total_tokens === "number" ? Math.max(completionTokens, usageRecord.total_tokens - promptTokens) : completionTokens;
  const promptTokensDetails = isPlainRecord(usageRecord.prompt_tokens_details) ? usageRecord.prompt_tokens_details : {};
  return {
    input_tokens: promptTokens,
    input_tokens_details: { cached_tokens: numberOrZero(promptTokensDetails.cached_tokens) },
    output_tokens: outputTokens,
  };
}

export type GeminiReplyMapping =
  | { ok: true; message: AnthropicShapedMessage; usageForLog: Record<string, unknown> }
  | { ok: false; error: string };

export function geminiChatCompletionToAnthropicMessage(responseJSON: unknown): GeminiReplyMapping {
  const parsedResponse = geminiChatCompletionSchema.safeParse(responseJSON);
  if (!parsedResponse.success) {
    return { ok: false, error: "Gemini response had no choices list" };
  }
  const response = parsedResponse.data;
  const firstChoice = response.choices[0];
  if (firstChoice === undefined) {
    return { ok: false, error: "Gemini response had no choices" };
  }

  const content: AnthropicShapedMessage["content"] = [];
  const { message: choiceMessage } = firstChoice;
  const answerText = choiceMessage.content ?? choiceMessage.refusal;
  if (typeof answerText === "string" && answerText !== "") {
    content.push({ type: "text", text: answerText });
  }
  for (const toolCallValue of choiceMessage.tool_calls ?? []) {
    const toolCall = geminiToolCallSchema.safeParse(toolCallValue);
    if (!toolCall.success) {
      return { ok: false, error: "Gemini tool call had no name or arguments" };
    }
    const toolCallId = toolCall.data.id || `gemini_call_${geminiToolCallIdCounter++}`;
    if (toolCall.data.extra_content !== undefined) {
      geminiExtraContentByToolCallId.set(toolCallId, toolCall.data.extra_content);
    }
    content.push({ type: "tool_use", id: toolCallId, name: toolCall.data.function.name, input: parseToolArguments(toolCall.data.function.arguments) });
  }

  const usageForLog = geminiUsageForLog(response.usage);
  const hasToolUse = content.some((block) => block.type === "tool_use");
  return {
    ok: true,
    usageForLog,
    message: {
      id: response.id,
      type: "message",
      role: "assistant",
      model: response.model,
      content,
      stop_reason: choiceMessage.refusal ? "refusal" : anthropicStopReasonForFinishReason(firstChoice.finish_reason ?? "stop", hasToolUse),
      usage: { input_tokens: numberOrZero(usageForLog.input_tokens), output_tokens: numberOrZero(usageForLog.output_tokens) },
    },
  };
}

// ---------- Calling Gemini ----------

function postToGeminiChatCompletions(override: GeminiBenchOverride, chatBody: Record<string, unknown>): Promise<Response> {
  return fetch("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", {
    method: "POST",
    headers: { authorization: `Bearer ${override.apiKey}`, "content-type": "application/json" },
    body: JSON.stringify(chatBody),
  });
}

/** One non-streaming call for requestAnthropicMessage: the Anthropic request in, an Anthropic-shaped message out. */
export async function requestBenchGeminiMessage(
  override: GeminiBenchOverride,
  routeName: string,
  anthropicBody: unknown,
): Promise<BenchMessageResult> {
  const mapping = anthropicBodyToGeminiChatBody(anthropicBody, override);
  if (!mapping.ok) {
    return { ok: false, status: 501, error: `BENCH_MODEL ${override.model} cannot take ${mapping.unsupported}` };
  }

  let upstreamResponse: Response;
  try {
    upstreamResponse = await postToGeminiChatCompletions(override, mapping.body);
  } catch (error) {
    console.error(`[${routeName}] Gemini request failed:`, error);
    return { ok: false, status: 502, error: "Gemini could not be reached" };
  }
  if (!upstreamResponse.ok) {
    const errorText = await upstreamResponse.text();
    console.error(`[${routeName}] Gemini API error ${upstreamResponse.status}: ${errorText}`);
    return { ok: false, status: upstreamResponse.status, error: errorText.length > 0 ? errorText : "Gemini request failed" };
  }

  let responseJSON: unknown;
  try {
    responseJSON = await upstreamResponse.json();
  } catch {
    return { ok: false, status: 502, error: "Gemini returned a body that was not JSON" };
  }
  const reply = geminiChatCompletionToAnthropicMessage(responseJSON);
  if (!reply.ok) {
    return { ok: false, status: 502, error: reply.error };
  }
  return {
    ok: true,
    message: reply.message,
    responseJSON: { model: reply.message.model ?? override.model, usage: reply.usageForLog },
  };
}

// ---------- /chat ----------

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function serverSentEvent(eventType: string, eventPayload: Record<string, unknown>): Uint8Array {
  return encoder.encode(`event: ${eventType}\ndata: ${JSON.stringify({ type: eventType, ...eventPayload })}\n\n`);
}

type StreamController = TransformStreamDefaultController<Uint8Array>;

/** The two events that open an Anthropic stream with one text block. */
function enqueueMessageStart(controller: StreamController, id: string | undefined, model: string | undefined): void {
  controller.enqueue(
    serverSentEvent("message_start", {
      message: { id, type: "message", role: "assistant", model, content: [], stop_reason: null, usage: { input_tokens: 0, output_tokens: 0 } },
    }),
  );
  controller.enqueue(serverSentEvent("content_block_start", { index: 0, content_block: { type: "text", text: "" } }));
}

function enqueueTextDelta(controller: StreamController, text: string): void {
  controller.enqueue(serverSentEvent("content_block_delta", { index: 0, delta: { type: "text_delta", text } }));
}

/** The three events that close an Anthropic stream. The vendor's usage fields go in the message_delta, which the benchmark reads. */
function enqueueMessageEnd(controller: StreamController, stopReason: string, usage: Record<string, unknown>): void {
  controller.enqueue(serverSentEvent("content_block_stop", { index: 0 }));
  controller.enqueue(serverSentEvent("message_delta", { delta: { stop_reason: stopReason, stop_sequence: null }, usage }));
  controller.enqueue(serverSentEvent("message_stop", {}));
}

function enqueueStreamError(controller: StreamController, message: string): void {
  controller.enqueue(serverSentEvent("error", { error: { type: "api_error", message } }));
}

/**
 * Splits a vendor's server-sent event stream into JSON events for onEvent, whichever way the bytes are chunked.
 * onEnd runs when the vendor sends its [DONE] marker and again when the stream closes, so it must ignore a second call.
 */
function anthropicStreamFromServerSentEvents(handlers: {
  onEvent: (controller: StreamController, eventJSON: unknown) => void;
  onEnd?: (controller: StreamController) => void;
}): TransformStream<Uint8Array, Uint8Array> {
  let bufferedText = "";

  const handleBlock = (controller: StreamController, eventBlock: string) => {
    const dataText = eventBlock
      .split("\n")
      .filter((blockLine) => blockLine.startsWith("data:"))
      .map((blockLine) => blockLine.slice(5).trimStart())
      .join("\n");
    if (dataText === "") {
      return;
    }
    if (dataText === "[DONE]") {
      handlers.onEnd?.(controller);
      return;
    }
    try {
      handlers.onEvent(controller, JSON.parse(dataText));
    } catch {
      // A block that is not JSON carries nothing the app reads.
    }
  };

  return new TransformStream<Uint8Array, Uint8Array>({
    transform(streamChunk, controller) {
      bufferedText += decoder.decode(streamChunk, { stream: true }).replaceAll("\r\n", "\n");
      const eventBlocks = bufferedText.split("\n\n");
      bufferedText = eventBlocks.pop() ?? "";
      for (const eventBlock of eventBlocks) {
        handleBlock(controller, eventBlock);
      }
    },
    flush(controller) {
      handleBlock(controller, bufferedText);
      handlers.onEnd?.(controller);
    },
  });
}

/**
 * Turns OpenAI's Responses stream into the Anthropic stream /chat's app and the benchmark read. Text deltas become
 * content_block_delta, and the usage OpenAI reports only at the end goes in the last message_delta, with the tier it used.
 */
export function openAIStreamToAnthropicStream(): TransformStream<Uint8Array, Uint8Array> {
  let messageStarted = false;
  let streamEnded = false;

  const startMessage = (controller: StreamController, id: string | undefined, model: string | undefined) => {
    if (messageStarted) {
      return;
    }
    messageStarted = true;
    enqueueMessageStart(controller, id, model);
  };

  return anthropicStreamFromServerSentEvents({
    onEvent(controller, eventJSON) {
      if (streamEnded || !isPlainRecord(eventJSON)) {
        return;
      }
      const response = isPlainRecord(eventJSON.response) ? eventJSON.response : {};
      switch (eventJSON.type) {
        case "response.created":
          startMessage(controller, typeof response.id === "string" ? response.id : undefined, typeof response.model === "string" ? response.model : undefined);
          break;
        case "response.output_text.delta":
          startMessage(controller, undefined, undefined);
          if (typeof eventJSON.delta === "string") {
            enqueueTextDelta(controller, eventJSON.delta);
          }
          break;
        case "response.completed":
        case "response.incomplete": {
          startMessage(controller, undefined, undefined);
          streamEnded = true;
          const incompleteDetails = isPlainRecord(response.incomplete_details) ? response.incomplete_details : {};
          const usage = isPlainRecord(response.usage) ? response.usage : undefined;
          enqueueMessageEnd(controller, incompleteDetails.reason === "max_output_tokens" ? "max_tokens" : "end_turn", {
            ...usage,
            // OpenAI reports usage and the tier it used only here, so the benchmark reads both from this event.
            ...(typeof response.service_tier === "string" ? { service_tier: response.service_tier } : {}),
          });
          break;
        }
        case "response.failed":
        case "error": {
          streamEnded = true;
          const errorSource = isPlainRecord(response.error) ? response.error : eventJSON;
          enqueueStreamError(controller, typeof errorSource.message === "string" ? errorSource.message : "OpenAI stream failed");
          break;
        }
      }
    },
  });
}

/**
 * Turns Gemini's Chat Completions stream into the same Anthropic stream. Text deltas become content_block_delta.
 * The finish reason and the usage (a last chunk with no choices, since the request sets include_usage) can arrive in
 * either order, so the closing events wait for the [DONE] marker or the end of the stream.
 */
export function geminiStreamToAnthropicStream(): TransformStream<Uint8Array, Uint8Array> {
  let messageStarted = false;
  let streamEnded = false;
  let stopReason = "end_turn";
  let usage: Record<string, unknown> = {};

  const startMessage = (controller: StreamController, id: string | undefined, model: string | undefined) => {
    if (messageStarted) {
      return;
    }
    messageStarted = true;
    enqueueMessageStart(controller, id, model);
  };

  return anthropicStreamFromServerSentEvents({
    onEvent(controller, eventJSON) {
      if (streamEnded || !isPlainRecord(eventJSON)) {
        return;
      }
      if (isPlainRecord(eventJSON.error)) {
        streamEnded = true;
        enqueueStreamError(controller, typeof eventJSON.error.message === "string" ? eventJSON.error.message : "Gemini stream failed");
        return;
      }
      startMessage(controller, typeof eventJSON.id === "string" ? eventJSON.id : undefined, typeof eventJSON.model === "string" ? eventJSON.model : undefined);
      const firstChoice = Array.isArray(eventJSON.choices) && isPlainRecord(eventJSON.choices[0]) ? eventJSON.choices[0] : {};
      const delta = isPlainRecord(firstChoice.delta) ? firstChoice.delta : {};
      if (typeof delta.content === "string" && delta.content !== "") {
        enqueueTextDelta(controller, delta.content);
      }
      if (typeof firstChoice.finish_reason === "string") {
        stopReason = anthropicStopReasonForFinishReason(firstChoice.finish_reason, false);
      }
      if (isPlainRecord(eventJSON.usage)) {
        usage = geminiUsageForLog(eventJSON.usage);
      }
    },
    onEnd(controller) {
      if (streamEnded) {
        return;
      }
      startMessage(controller, undefined, undefined);
      streamEnded = true;
      enqueueMessageEnd(controller, stopReason, usage);
    },
  });
}

/** The /chat request body with its model replaced, and its effort when BENCH_EFFORT is set. Text that is not a JSON object stays as sent. */
export function claudeChatBodyText(chatBodyText: string, override: ClaudeBenchOverride): string {
  try {
    const chatBody: unknown = JSON.parse(chatBodyText);
    return isPlainRecord(chatBody) ? JSON.stringify(applyClaudeBenchOverride(chatBody, override)) : chatBodyText;
  } catch {
    return chatBodyText;
  }
}

/** /chat on a GPT model: the app's request goes to OpenAI, and the answer streams back as Anthropic events. */
export async function forwardChatToOpenAI(override: OpenAIBenchOverride, chatBodyText: string): Promise<Response> {
  let chatBody: unknown;
  try {
    chatBody = JSON.parse(chatBodyText);
  } catch {
    return new Response(JSON.stringify({ error: "Request body must be JSON" }), { status: 400, headers: { "content-type": "application/json" } });
  }
  const mapping = anthropicBodyToOpenAIResponsesBody(chatBody, override);
  if (!mapping.ok) {
    return new Response(JSON.stringify({ error: `BENCH_MODEL ${override.model} cannot take ${mapping.unsupported}` }), {
      status: 501,
      headers: { "content-type": "application/json" },
    });
  }

  const upstreamResponse = await postToOpenAIResponses(override, { ...mapping.body, stream: true });
  if (!upstreamResponse.ok || upstreamResponse.body === null) {
    const errorText = await upstreamResponse.text();
    console.error(`[/chat] OpenAI API error ${upstreamResponse.status}: ${errorText}`);
    return new Response(errorText, { status: upstreamResponse.status, headers: { "content-type": "application/json" } });
  }
  return new Response(upstreamResponse.body.pipeThrough(openAIStreamToAnthropicStream()), {
    status: 200,
    headers: { "content-type": "text/event-stream", "cache-control": "no-cache" },
  });
}

/** /chat on a Gemini model: the app's request goes to Gemini's Chat Completions endpoint, and the answer streams back as Anthropic events. */
export async function forwardChatToGemini(override: GeminiBenchOverride, chatBodyText: string): Promise<Response> {
  let chatBody: unknown;
  try {
    chatBody = JSON.parse(chatBodyText);
  } catch {
    return new Response(JSON.stringify({ error: "Request body must be JSON" }), { status: 400, headers: { "content-type": "application/json" } });
  }
  const mapping = anthropicBodyToGeminiChatBody(chatBody, override);
  if (!mapping.ok) {
    return new Response(JSON.stringify({ error: `BENCH_MODEL ${override.model} cannot take ${mapping.unsupported}` }), {
      status: 501,
      headers: { "content-type": "application/json" },
    });
  }

  // include_usage makes Gemini send the token counts in a last chunk, which the benchmark prices.
  const upstreamResponse = await postToGeminiChatCompletions(override, { ...mapping.body, stream: true, stream_options: { include_usage: true } });
  if (!upstreamResponse.ok || upstreamResponse.body === null) {
    const errorText = await upstreamResponse.text();
    console.error(`[/chat] Gemini API error ${upstreamResponse.status}: ${errorText}`);
    return new Response(errorText, { status: upstreamResponse.status, headers: { "content-type": "application/json" } });
  }
  return new Response(upstreamResponse.body.pipeThrough(geminiStreamToAnthropicStream()), {
    status: 200,
    headers: { "content-type": "text/event-stream", "cache-control": "no-cache" },
  });
}
