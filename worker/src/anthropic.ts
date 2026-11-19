/**
 * Helpers the Worker routes share: JSON responses, request body parsing, the token usage log,
 * one-line schema errors, the system prompt cache breakpoint, and one Anthropic Messages call whose
 * answer is the whole reply, the first text block as text, or that text parsed as JSON.
 */

import { z } from "zod";
import {
  applyClaudeBenchOverride,
  benchModelOverride,
  type OpenAIBenchOverride,
  requestBenchGeminiMessage,
  requestBenchOpenAIMessage,
} from "./benchModelOverride";

// Passthrough keeps every field of each block and of the reply, because /voice-command reads tool_use inputs and a
// caller may send the blocks back to Anthropic unchanged.
const anthropicMessageSchema = z
  .object({
    content: z.array(z.object({ type: z.string(), text: z.string().optional() }).passthrough()),
    stop_reason: z.string().nullish(),
  })
  .passthrough();

// OpenAI names the tier it used at the top of the reply, and Anthropic names it inside usage.
const modelUsageSchema = z.object({ model: z.string().optional(), usage: z.record(z.unknown()), service_tier: z.string().nullish() });

/**
 * Logs the token counts a model reply reports, so `wrangler tail` shows what each route spends.
 * The line also names the model and, for an OpenAI reply, the service tier, because the benchmark prices each line by them.
 */
export function logModelUsage(routeName: string, modelResponseJSON: unknown): void {
  const parsedResponse = modelUsageSchema.safeParse(modelResponseJSON);
  if (parsedResponse.success) {
    const { model, usage, service_tier } = parsedResponse.data;
    console.log(`[${routeName}] usage ${JSON.stringify({ model, ...usage, ...(service_tier == null ? {} : { service_tier }) })}`);
  }
}

export type AnthropicMessage = z.infer<typeof anthropicMessageSchema>;

/**
 * Zod's own message is pretty-printed JSON across many lines, so a rejection logged with it keeps only
 * its first line in tools that read the Worker log line by line. This names each issue as "path: message".
 */
export function zodIssuesOnOneLine(zodError: z.ZodError): string {
  return zodError.issues
    .map((issue) => (issue.path.length > 0 ? `${issue.path.join(".")}: ${issue.message}` : issue.message))
    .join("; ");
}

export function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function parseJSONRequest<RequestBody>(
  request: Request,
  requestSchema: z.ZodType<RequestBody, z.ZodTypeDef, unknown>,
): Promise<{ ok: true; requestBody: RequestBody } | { ok: false; response: Response }> {
  let requestJSON: unknown;
  try {
    requestJSON = await request.json();
  } catch {
    return { ok: false, response: jsonResponse({ error: "Request body must be JSON" }, 400) };
  }

  const parsedRequest = requestSchema.safeParse(requestJSON);
  if (!parsedRequest.success) {
    return { ok: false, response: jsonResponse({ error: parsedRequest.error.message }, 400) };
  }
  return { ok: true, requestBody: parsedRequest.data };
}

/** Thinking blocks come first, so the answer is the first text block. */
function firstTextBlock(message: AnthropicMessage): string | undefined {
  return message.content.find((contentBlock) => contentBlock.type === "text")?.text;
}

/** replyJSON is undefined when the reply had no JSON text, so the caller's schema check names the problem. */
export async function requestAnthropicReplyJSON(
  anthropicAPIKey: string,
  routeName: string,
  messagesRequestBody: unknown,
  routeOpenAIModel?: OpenAIBenchOverride,
): Promise<{ ok: true; replyJSON: unknown } | { ok: false; response: Response }> {
  const anthropicReply = await requestAnthropicReplyText(anthropicAPIKey, routeName, messagesRequestBody, routeOpenAIModel);
  if (!anthropicReply.ok) {
    return anthropicReply;
  }
  if (anthropicReply.replyText === undefined) {
    return { ok: true, replyJSON: undefined };
  }
  try {
    return { ok: true, replyJSON: JSON.parse(anthropicReply.replyText) };
  } catch {
    return { ok: true, replyJSON: undefined };
  }
}

/** replyText is undefined when the reply had no text block. */
export async function requestAnthropicReplyText(
  anthropicAPIKey: string,
  routeName: string,
  messagesRequestBody: unknown,
  routeOpenAIModel?: OpenAIBenchOverride,
): Promise<{ ok: true; replyText: string | undefined } | { ok: false; response: Response }> {
  const anthropicMessage = await requestAnthropicMessage(anthropicAPIKey, routeName, messagesRequestBody, routeOpenAIModel);
  if (!anthropicMessage.ok) {
    return anthropicMessage;
  }
  return { ok: true, replyText: firstTextBlock(anthropicMessage.message) };
}

/**
 * One non-streaming Anthropic Messages call. A successful result carries the reply with its content list checked,
 * so a caller that needs tool_use blocks or the stop reason can read them.
 * A route that runs on a GPT model passes routeOpenAIModel, and its Anthropic-shaped request goes to OpenAI through the
 * same mapping the benchmark uses, so the route reads the same reply shape on either vendor.
 * A Worker started for a benchmark with BENCH_MODEL swaps the model here (see benchModelOverride.ts), ahead of the route's
 * own model, and any other Worker never does.
 */
export async function requestAnthropicMessage(
  anthropicAPIKey: string,
  routeName: string,
  messagesRequestBody: unknown,
  routeOpenAIModel?: OpenAIBenchOverride,
): Promise<{ ok: true; message: AnthropicMessage } | { ok: false; response: Response }> {
  const benchOverride = benchModelOverride() ?? routeOpenAIModel;
  if (benchOverride?.provider === "openai" || benchOverride?.provider === "gemini") {
    const vendorName = benchOverride.provider === "openai" ? "OpenAI" : "Gemini";
    const vendorReply =
      benchOverride.provider === "openai"
        ? await requestBenchOpenAIMessage(benchOverride, routeName, messagesRequestBody)
        : await requestBenchGeminiMessage(benchOverride, routeName, messagesRequestBody);
    if (!vendorReply.ok) {
      return { ok: false, response: jsonResponse({ error: vendorReply.error }, vendorReply.status) };
    }
    logModelUsage(routeName, vendorReply.responseJSON);
    const parsedVendorMessage = anthropicMessageSchema.safeParse(vendorReply.message);
    if (!parsedVendorMessage.success) {
      return { ok: false, response: jsonResponse({ error: `${vendorName} response had no content list` }, 502) };
    }
    return { ok: true, message: parsedVendorMessage.data };
  }
  const sentRequestBody = benchOverride === undefined ? messagesRequestBody : applyClaudeBenchOverride(messagesRequestBody, benchOverride);

  let anthropicResponse: Response;
  try {
    anthropicResponse = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": anthropicAPIKey,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify(withCachedSystemPrompt(sentRequestBody)),
    });
  } catch (error) {
    // Without this, a DNS or connection failure reaches the app as the outer catch's generic 500, which does not name Anthropic.
    console.error(`[${routeName}] Anthropic request failed:`, error);
    return { ok: false, response: jsonResponse({ error: "Anthropic could not be reached" }, 502) };
  }

  if (!anthropicResponse.ok) {
    const errorText = await anthropicResponse.text();
    console.error(`[${routeName}] Anthropic API error ${anthropicResponse.status}: ${errorText}`);
    return {
      ok: false,
      response: jsonResponse(
        { error: errorText.length > 0 ? errorText : "Anthropic request failed" },
        anthropicResponse.status,
      ),
    };
  }

  let anthropicJSON: unknown;
  try {
    anthropicJSON = await anthropicResponse.json();
  } catch {
    return { ok: false, response: jsonResponse({ error: "Anthropic returned a body that was not JSON" }, 502) };
  }
  logModelUsage(routeName, anthropicJSON);

  const parsedMessage = anthropicMessageSchema.safeParse(anthropicJSON);
  if (!parsedMessage.success) {
    return { ok: false, response: jsonResponse({ error: "Anthropic response had no content list" }, 502) };
  }
  return { ok: true, message: parsedMessage.data };
}

/**
 * Every route sends the same system prompt on every call, ahead of a frame or answer that never repeats.
 * A cache breakpoint on the system prompt lets later calls within 5 minutes read it at a tenth of the input price
 * or less, while the part after it is never written to the cache. Any other body passes through unchanged.
 */
export function withCachedSystemPrompt(messagesRequestBody: unknown): unknown {
  if (typeof messagesRequestBody !== "object" || messagesRequestBody === null || !("system" in messagesRequestBody)) {
    return messagesRequestBody;
  }
  const { system } = messagesRequestBody;
  if (typeof system !== "string" || system.length === 0) {
    return messagesRequestBody;
  }
  return { ...messagesRequestBody, system: [{ type: "text", text: system, cache_control: { type: "ephemeral" } }] };
}
