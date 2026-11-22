// The two judging models and the calls to them. A judge is a different vendor from the other, so a judge that favors
// its own family is offset by the other. fetch is a parameter, so judgeModels.test.ts runs the calls without a network.

import { judgeSystemPrompt, judgeVerdictSchema, parseJudgeVerdict, type JudgePromptPart } from "./judgeRender.ts";
import type { Verdict } from "./judgePairs.ts";
import { isRecord, usageLineFromUsageObject, type UsageLine } from "./usage.ts";

export type JudgeModel = { provider: "anthropic" | "openai"; model: string };

/** Run on standard tiers, since a judge has no hurry. */
export const judgeModels: Record<string, JudgeModel> = {
  opus: { provider: "anthropic", model: "claude-opus-5-5" },
  sol: { provider: "openai", model: "gpt-6.1-sol" },
};

export type JudgeKeys = { anthropicAPIKey: string | undefined; openAIAPIKey: string | undefined };

/** Reads KEY=value lines from a .dev.vars file, with or without quotes. */
export function parseDevVars(devVarsText: string): Record<string, string> {
  const values: Record<string, string> = {};
  for (const devVarsLine of devVarsText.split("\n")) {
    const lineMatch = devVarsLine.match(/^\s*([A-Z0-9_]+)\s*=\s*"?([^"]*?)"?\s*$/);
    if (lineMatch !== null) {
      values[lineMatch[1]] = lineMatch[2];
    }
  }
  return values;
}

const maximumOutputTokens = 8000;

function anthropicContent(parts: JudgePromptPart[]) {
  return parts.map((part) =>
    part.kind === "text"
      ? { type: "text", text: part.text }
      : { type: "image", source: { type: "base64", media_type: part.mediaType, data: part.base64 } },
  );
}

function openAIContent(parts: JudgePromptPart[]) {
  return parts.map((part) =>
    part.kind === "text"
      ? { type: "input_text", text: part.text }
      : { type: "input_image", image_url: `data:${part.mediaType};base64,${part.base64}`, detail: "high" },
  );
}

/** The URL, headers, and body of one judging call. Exported so a test can read what would be sent. */
export function judgeRequest(
  judge: JudgeModel,
  parts: JudgePromptPart[],
  effort: string,
  keys: JudgeKeys,
): { url: string; headers: Record<string, string>; body: Record<string, unknown> } {
  if (judge.provider === "anthropic") {
    return {
      url: "https://api.anthropic.com/v1/messages",
      headers: { "x-api-key": keys.anthropicAPIKey ?? "", "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: {
        model: judge.model,
        // Thinking counts toward this limit.
        max_tokens: maximumOutputTokens,
        system: judgeSystemPrompt,
        output_config: { effort, format: { type: "json_schema", schema: judgeVerdictSchema } },
        messages: [{ role: "user", content: anthropicContent(parts) }],
      },
    };
  }
  return {
    url: "https://api.openai.com/v1/responses",
    headers: { authorization: `Bearer ${keys.openAIAPIKey ?? ""}`, "content-type": "application/json" },
    body: {
      model: judge.model,
      instructions: judgeSystemPrompt,
      input: [{ role: "user", content: openAIContent(parts) }],
      reasoning: { effort },
      // Reasoning counts toward this limit.
      max_output_tokens: maximumOutputTokens,
      text: { format: { type: "json_schema", name: "verdict", schema: judgeVerdictSchema, strict: true } },
    },
  };
}

/** The reply's text and its usage, whichever vendor answered. */
export function judgeReplyText(judge: JudgeModel, responseJSON: unknown): { text: string | undefined; usage: UsageLine } {
  const response = isRecord(responseJSON) ? responseJSON : {};
  const usageObject = {
    model: typeof response.model === "string" ? response.model : judge.model,
    ...(isRecord(response.usage) ? response.usage : {}),
    ...(typeof response.service_tier === "string" ? { service_tier: response.service_tier } : {}),
  };
  const usage = usageLineFromUsageObject("/judge", usageObject);
  if (judge.provider === "anthropic") {
    const textBlock = (Array.isArray(response.content) ? response.content : []).filter(isRecord).find((block) => block.type === "text");
    return { text: typeof textBlock?.text === "string" ? textBlock.text : undefined, usage };
  }
  const texts: string[] = [];
  for (const outputItem of (Array.isArray(response.output) ? response.output : []).filter(isRecord)) {
    for (const contentPart of (Array.isArray(outputItem.content) ? outputItem.content : []).filter(isRecord)) {
      if (contentPart.type === "output_text" && typeof contentPart.text === "string") {
        texts.push(contentPart.text);
      }
    }
  }
  return { text: texts.length > 0 ? texts.join("\n") : undefined, usage };
}

export type JudgeCallResult =
  | { ok: true; winner: Verdict; reason: string; usage: UsageLine }
  | { ok: false; error: string };

/** One judging call, retried on a 429 or a 5xx, since a bakeoff of a few hundred calls will meet one. */
export async function requestJudgeVerdict(
  judge: JudgeModel,
  parts: JudgePromptPart[],
  options: { keys: JudgeKeys; effort: string; fetchImpl?: typeof fetch; retryDelayMs?: number },
): Promise<JudgeCallResult> {
  const { url, headers, body } = judgeRequest(judge, parts, options.effort, options.keys);
  const fetchImpl = options.fetchImpl ?? fetch;
  const maximumAttempts = 3;
  let lastError = "no attempt was made";
  for (let attempt = 1; attempt <= maximumAttempts; attempt += 1) {
    if (attempt > 1) {
      await new Promise((resolve) => setTimeout(resolve, (options.retryDelayMs ?? 3000) * (attempt - 1)));
    }
    let response: Response;
    try {
      response = await fetchImpl(url, { method: "POST", headers, body: JSON.stringify(body) });
    } catch (error) {
      lastError = `the request failed: ${String(error)}`;
      continue;
    }
    if (response.status === 429 || response.status >= 500) {
      lastError = `HTTP ${response.status}`;
      continue;
    }
    const responseText = await response.text();
    if (!response.ok) {
      return { ok: false, error: `HTTP ${response.status}: ${responseText.slice(0, 300)}` };
    }
    let responseJSON: unknown;
    try {
      responseJSON = JSON.parse(responseText);
    } catch {
      return { ok: false, error: "the reply was not JSON" };
    }
    const { text, usage } = judgeReplyText(judge, responseJSON);
    const verdict = text === undefined ? undefined : parseJudgeVerdict(text);
    if (verdict === undefined) {
      return { ok: false, error: `the reply held no verdict: ${String(text).slice(0, 200)}` };
    }
    return { ok: true, ...verdict, usage };
  }
  return { ok: false, error: lastError };
}
