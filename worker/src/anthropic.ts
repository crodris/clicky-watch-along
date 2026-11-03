/**
 * Helpers the Worker routes share: JSON responses, request body parsing, and
 * one Anthropic Messages call whose answer is the first text block parsed as JSON.
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

type AnthropicMessage = z.infer<typeof anthropicMessageSchema>;

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

/** Thinking blocks come first, so the answer is the first text block. Text that is not JSON counts as no answer. */
function firstTextBlockJSON(message: AnthropicMessage): unknown {
  const textBlock = message.content.find((contentBlock) => contentBlock.type === "text");
  if (textBlock?.text === undefined) {
    return undefined;
  }
  try {
    return JSON.parse(textBlock.text);
  } catch {
    return undefined;
  }
}

/** replyJSON is undefined when the reply had no JSON text, so the caller's schema check names the problem. */
export async function requestAnthropicReplyJSON(
  anthropicAPIKey: string,
  routeName: string,
  messagesRequestBody: unknown,
): Promise<{ ok: true; replyJSON: unknown } | { ok: false; response: Response }> {
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

  const parsedMessage = anthropicMessageSchema.safeParse(anthropicJSON);
  if (!parsedMessage.success) {
    return { ok: false, response: jsonResponse({ error: "Anthropic response had no content list" }, 502) };
  }
  return { ok: true, replyJSON: firstTextBlockJSON(parsedMessage.data) };
}
