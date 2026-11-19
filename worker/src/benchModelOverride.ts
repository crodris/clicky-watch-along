/**
 * A local benchmark override that runs the model routes on another model, for bench/bench.ts bakeoffs.
 *
 * It does nothing unless the Worker is started with --var BENCH_MODEL:<model>, so the deployed Worker and the app's
 * Worker on port 8787 never use it, and wrangler.toml never sets it. Each Worker process holds one override for its whole
 * life, so a bakeoff starts one Worker per model, each on its own port.
 *
 *   BENCH_MODEL         claude-* swaps the model of every call that goes through requestAnthropicMessage and of /chat.
 *                       gpt-* sends those calls to OpenAI's Responses API instead, in the shape the route already reads.
 *   BENCH_EFFORT        Replaces the route's own effort. Claude: low, medium, high, xhigh, or max.
 *                       GPT: none, minimal, low, medium, high, or xhigh.
 *   BENCH_SERVICE_TIER  GPT only, such as ultrafast. The tier OpenAI reports back goes in the usage log line.
 *
 * /v1/messages (the agent harness) and /live-scene's GPT path never use it.
 * Every prompt here was tuned for Claude, so a GPT model that loses may only have lost to the prompt.
 */

import { z } from "zod";

const claudeEfforts = ["low", "medium", "high", "xhigh", "max"];
const gptEfforts = ["none", "minimal", "low", "medium", "high", "xhigh"];
const serviceTierPattern = /^[a-z_]+$/;

/**
 * The efforts a GPT model gets for a route that turns thinking off, lowest first. Which of them a model accepts is
 * not listed anywhere the Worker can read, so a 400 that names the effort moves to the next one.
 */
const thinkingOffEffortLadder = ["none", "minimal", "low"];

export type ClaudeBenchOverride = { provider: "anthropic"; model: string; effort?: string };
export type OpenAIBenchOverride = { provider: "openai"; model: string; apiKey: string; effort?: string; serviceTier?: string };
export type BenchModelOverride = ClaudeBenchOverride | OpenAIBenchOverride;

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

  return `BENCH_MODEL must start with claude- or gpt-, not ${model}`;
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

export type OpenAIRequestMapping = { ok: true; body: Record<string, unknown> } | { ok: false; unsupported: string };

function openAIContentPart(role: "user" | "assistant", block: Record<string, unknown>): Record<string, unknown> | string {
  if (block.type === "text" && typeof block.text === "string") {
    return { type: role === "user" ? "input_text" : "output_text", text: block.text };
  }
  if (block.type === "image" && role === "user") {
    const imageSource = imageSourceSchema.safeParse(block.source);
    if (imageSource.success) {
      return {
        type: "input_image",
        image_url: `data:${imageSource.data.media_type};base64,${imageSource.data.data}`,
        detail: "high",
      };
    }
    return "an image that is not base64";
  }
  return `a ${String(block.type)} block`;
}

/** The effort GPT gets: BENCH_EFFORT first, then the lowest effort for thinking off, then the route's own effort. */
function reasoningEffortFor(
  request: z.infer<typeof anthropicRequestSchema>,
  override: OpenAIBenchOverride,
  thinkingOffEffort: string,
): string | undefined {
  if (override.effort !== undefined) {
    return override.effort;
  }
  if (request.thinking?.type === "disabled") {
    return thinkingOffEffort;
  }
  const routeEffort = request.output_config?.effort;
  // Claude's top effort is called xhigh by OpenAI, which has no max.
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
): OpenAIRequestMapping {
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

export type BenchOpenAIMessageResult =
  | {
      ok: true;
      message: AnthropicShapedMessage;
      /** OpenAI's own reply, which logModelUsage reads: its usage fields, which the benchmark prices, and the tier it used. */
      responseJSON: unknown;
    }
  | { ok: false; status: number; error: string };

/** One non-streaming call for requestAnthropicMessage: the Anthropic request in, an Anthropic-shaped message out. */
export async function requestBenchOpenAIMessage(
  override: OpenAIBenchOverride,
  routeName: string,
  anthropicBody: unknown,
): Promise<BenchOpenAIMessageResult> {
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

// ---------- /chat ----------

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function serverSentEvent(eventType: string, eventPayload: Record<string, unknown>): Uint8Array {
  return encoder.encode(`event: ${eventType}\ndata: ${JSON.stringify({ type: eventType, ...eventPayload })}\n\n`);
}

/**
 * Turns OpenAI's Responses stream into the Anthropic stream /chat's app and the benchmark read. Text deltas become
 * content_block_delta, and the usage OpenAI reports only at the end goes in the last message_delta, with the tier it used.
 */
export function openAIStreamToAnthropicStream(): TransformStream<Uint8Array, Uint8Array> {
  let bufferedText = "";
  let messageStarted = false;
  let streamEnded = false;

  const startMessage = (controller: TransformStreamDefaultController<Uint8Array>, id: string | undefined, model: string | undefined) => {
    if (messageStarted) {
      return;
    }
    messageStarted = true;
    controller.enqueue(
      serverSentEvent("message_start", {
        message: { id, type: "message", role: "assistant", model, content: [], stop_reason: null, usage: { input_tokens: 0, output_tokens: 0 } },
      }),
    );
    controller.enqueue(serverSentEvent("content_block_start", { index: 0, content_block: { type: "text", text: "" } }));
  };

  const handleEvent = (controller: TransformStreamDefaultController<Uint8Array>, eventJSON: unknown) => {
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
          controller.enqueue(serverSentEvent("content_block_delta", { index: 0, delta: { type: "text_delta", text: eventJSON.delta } }));
        }
        break;
      case "response.completed":
      case "response.incomplete": {
        startMessage(controller, undefined, undefined);
        streamEnded = true;
        const incompleteDetails = isPlainRecord(response.incomplete_details) ? response.incomplete_details : {};
        const usage = isPlainRecord(response.usage) ? response.usage : undefined;
        controller.enqueue(serverSentEvent("content_block_stop", { index: 0 }));
        controller.enqueue(
          serverSentEvent("message_delta", {
            delta: { stop_reason: incompleteDetails.reason === "max_output_tokens" ? "max_tokens" : "end_turn", stop_sequence: null },
            // OpenAI reports usage and the tier it used only here, so the benchmark reads both from this event.
            usage: { ...usage, ...(typeof response.service_tier === "string" ? { service_tier: response.service_tier } : {}) },
          }),
        );
        controller.enqueue(serverSentEvent("message_stop", {}));
        break;
      }
      case "response.failed":
      case "error": {
        streamEnded = true;
        const errorSource = isPlainRecord(response.error) ? response.error : eventJSON;
        const errorMessage = typeof errorSource.message === "string" ? errorSource.message : "OpenAI stream failed";
        controller.enqueue(serverSentEvent("error", { error: { type: "api_error", message: errorMessage } }));
        break;
      }
    }
  };

  const handleBlock = (controller: TransformStreamDefaultController<Uint8Array>, eventBlock: string) => {
    const dataText = eventBlock
      .split("\n")
      .filter((blockLine) => blockLine.startsWith("data:"))
      .map((blockLine) => blockLine.slice(5).trimStart())
      .join("\n");
    if (dataText === "" || dataText === "[DONE]") {
      return;
    }
    try {
      handleEvent(controller, JSON.parse(dataText));
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
