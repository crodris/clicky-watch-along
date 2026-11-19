// Token usage of one model call, and what it cost. Pure functions, so usage.test.ts runs them without a Worker.

// USD per million tokens, from https://platform.claude.com/docs/en/about-claude/pricing (fetched 2026-11-13).
const anthropicPricesPerMillionTokens: Record<string, { input: number; cacheWrite: number; cacheRead: number; output: number }> = {
  "claude-sonnet-4-6": { input: 3, cacheWrite: 3.75, cacheRead: 0.3, output: 15 },
  "claude-sonnet-5-5": { input: 2, cacheWrite: 2.5, cacheRead: 0.1, output: 10 },
  "claude-opus-5-5": { input: 4, cacheWrite: 5, cacheRead: 0.2, output: 20 },
  "claude-haiku-5-5": { input: 0.1, cacheWrite: 0.125, cacheRead: 0.01, output: 0.5 },
};

// USD per million tokens at the standard tier. OpenAI's pricing page refuses automated fetches, so these are
// estimates. Sol and Astra are the standard prices from OpenAI's GPT-6.2 announcement (2026-11-17), and cached input is
// 5 percent of input. gpt-6-sol and gpt-6-astra are assumed to cost what 6.1 Sol and 6.2 Astra do, and gpt-6-luna's
// price was never published, so $0.5 and $2 are a guess. Check them before trusting a cost comparison with Luna.
// OpenAI counts cached tokens inside input_tokens.
const openAIStandardPricesPerMillionTokens: Record<string, { input: number; cachedInput: number; output: number }> = {
  "gpt-6.1-sol": { input: 2, cachedInput: 0.1, output: 10 },
  "gpt-6.2-sol": { input: 2, cachedInput: 0.1, output: 10 },
  "gpt-6-sol": { input: 2, cachedInput: 0.1, output: 10 },
  "gpt-6.2-astra": { input: 8, cachedInput: 0.4, output: 40 },
  "gpt-6-astra": { input: 8, cachedInput: 0.4, output: 40 },
  "gpt-6-luna": { input: 0.5, cachedInput: 0.025, output: 2 },
};

// What each service tier costs as a multiple of standard. Ultrafast is the multiple reported for GPT-6.1 Sol.
// A tier missing here has no known price, so its cost is unknown.
const openAIServiceTierPriceMultiples: Record<string, number> = { default: 1, auto: 1, standard: 1, ultrafast: 6 };

export type UsageLine = {
  route: string;
  model: string;
  /** The tier OpenAI reported for a GPT call. Undefined for a Claude call, or when OpenAI named none. */
  serviceTier: string | undefined;
  inputTokens: number;
  cacheWriteTokens: number;
  cacheReadTokens: number;
  outputTokens: number;
};

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function numberField(record: Record<string, unknown>, key: string): number {
  const value = record[key];
  return typeof value === "number" ? value : 0;
}

/** Reads an Anthropic or OpenAI usage object, which name the cache and output fields differently. */
export function usageLineFromUsageObject(route: string, usageObject: Record<string, unknown>): UsageLine {
  const inputTokensDetails = isRecord(usageObject.input_tokens_details) ? usageObject.input_tokens_details : {};
  return {
    route,
    model: typeof usageObject.model === "string" ? usageObject.model : "unknown",
    serviceTier: typeof usageObject.service_tier === "string" ? usageObject.service_tier : undefined,
    inputTokens: numberField(usageObject, "input_tokens"),
    cacheWriteTokens: numberField(usageObject, "cache_creation_input_tokens"),
    cacheReadTokens: numberField(usageObject, "cache_read_input_tokens") || numberField(inputTokensDetails, "cached_tokens"),
    outputTokens: numberField(usageObject, "output_tokens"),
  };
}

/** Null when the model or its tier has no price, so one unpriced reply cannot end a run that has already spent money. */
export function costOfUsageLine(usageLine: UsageLine): number | null {
  // A reply can name a dated snapshot, such as gpt-6.2-sol-2026-11-17, so match the model the snapshot belongs to.
  const openAIModel = Object.keys(openAIStandardPricesPerMillionTokens).find(
    (modelID) => usageLine.model === modelID || usageLine.model.startsWith(`${modelID}-`),
  );
  if (openAIModel !== undefined) {
    // The Worker asks OpenAI for the Ultrafast tier on every /live-scene call, so a line that names no tier is Ultrafast there.
    const serviceTier = usageLine.serviceTier ?? (usageLine.route === "/live-scene" ? "ultrafast" : "default");
    const tierPriceMultiple = openAIServiceTierPriceMultiples[serviceTier];
    if (tierPriceMultiple === undefined) {
      console.warn(`No price for service tier ${serviceTier}, so its cost is recorded as unknown. Add it to openAIServiceTierPriceMultiples.`);
      return null;
    }
    const openAIPrices = openAIStandardPricesPerMillionTokens[openAIModel];
    return (
      tierPriceMultiple *
      ((usageLine.inputTokens - usageLine.cacheReadTokens) * openAIPrices.input +
        usageLine.cacheReadTokens * openAIPrices.cachedInput +
        usageLine.outputTokens * openAIPrices.output)
    ) / 1_000_000;
  }
  const prices = anthropicPricesPerMillionTokens[usageLine.model];
  if (prices === undefined) {
    console.warn(`No price for model ${usageLine.model}, so its cost is recorded as unknown. Add it to the price tables in usage.ts.`);
    return null;
  }
  return (
    (usageLine.inputTokens * prices.input +
      usageLine.cacheWriteTokens * prices.cacheWrite +
      usageLine.cacheReadTokens * prices.cacheRead +
      usageLine.outputTokens * prices.output) /
    1_000_000
  );
}

/**
 * Folds one /chat stream event into the usage so far. message_start names the model and starts the counts, and each
 * message_delta adds to them: Anthropic repeats output_tokens there, and OpenAI reports every count and its tier only in
 * the last one, since a Responses stream carries no usage before it completes.
 */
export function usageAfterChatStreamEvent(usageObject: Record<string, unknown>, streamEvent: Record<string, unknown>): Record<string, unknown> {
  if (streamEvent.type === "message_start" && isRecord(streamEvent.message)) {
    const startUsage = isRecord(streamEvent.message.usage) ? streamEvent.message.usage : {};
    return { ...startUsage, model: streamEvent.message.model };
  }
  if (streamEvent.type === "message_delta" && isRecord(streamEvent.usage)) {
    return { ...usageObject, ...streamEvent.usage };
  }
  return usageObject;
}
