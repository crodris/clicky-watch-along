/**
 * Helpers the Worker routes share: JSON responses, request body parsing, the token usage log,
 * one-line schema errors, and one Anthropic Messages call whose answer is the first text block,
 * as text or parsed as JSON.
 */

import { z } from "zod";

const anthropicMessageSchema = z.object({
  content: z.array(
    z.object({
      type: z.string(),
      text: z.string().optional(),
    }),
  ),
});

const modelUsageSchema = z.object({ model: z.string().optional(), usage: z.record(z.unknown()) });

/**
 * Logs the token counts a model reply reports, so `wrangler tail` shows what each route spends.
 * The line also names the model, because the benchmark prices each line by it.
 */
export function logModelUsage(routeName: string, modelResponseJSON: unknown): void {
  const parsedResponse = modelUsageSchema.safeParse(modelResponseJSON);
  if (parsedResponse.success) {
    const { model, usage } = parsedResponse.data;
    console.log(`[${routeName}] usage ${JSON.stringify({ model, ...usage })}`);
  }
}

type AnthropicMessage = z.infer<typeof anthropicMessageSchema>;

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
): Promise<{ ok: true; replyJSON: unknown } | { ok: false; response: Response }> {
  const anthropicReply = await requestAnthropicReplyText(anthropicAPIKey, routeName, messagesRequestBody);
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
): Promise<{ ok: true; replyText: string | undefined } | { ok: false; response: Response }> {
  const anthropicResponse = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": anthropicAPIKey,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify(messagesRequestBody),
  });

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
  return { ok: true, replyText: firstTextBlock(parsedMessage.data) };
}
