import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { applyDecisionRule, nearestRankPercentile, sideNumbers, winRateFromSummary, type GateSample } from "./decisionRule.ts";

function sample(caseId: string, totalMs: number, model = "gpt-6.1-sol", passed = true): GateSample {
  return { caseId, httpStatus: 200, totalMs, costUSD: 0.3, quality: { passed }, usageLines: [{ model, outputTokens: 1000 }] };
}

describe("decision rule", () => {
  it("reads the nearest-rank p50 and p95 that bench.ts prints", () => {
    assert.equal(nearestRankPercentile([30, 10, 20, 40], 0.5), 20);
    assert.equal(nearestRankPercentile([30, 10, 20, 40], 0.95), 40);
  });

  it("drops a sample a model outside the allowed list answered, such as a Sonnet fallback", () => {
    const numbers = sideNumbers([sample("live-scene", 20_000), sample("live-scene", 30_000, "claude-sonnet-5-5")], ["gpt-6.1-sol"]);

    assert.equal(numbers.samples, 1);
    assert.equal(numbers.droppedSamples, 1);
    assert.equal(numbers.p50Ms, 20_000);
  });

  it("passes on the faster arm only when the p50 is at least 25% lower and the p95 is no worse", () => {
    const baseline = sideNumbers([sample("a", 20_000), sample("a", 30_000)]);

    assert.equal(applyDecisionRule(baseline, sideNumbers([sample("a", 15_000), sample("a", 30_000)]), null).passes, true);
    assert.equal(applyDecisionRule(baseline, sideNumbers([sample("a", 15_100), sample("a", 20_000)]), null).passes, false);
    assert.equal(applyDecisionRule(baseline, sideNumbers([sample("a", 10_000), sample("a", 31_000)]), null).passes, false);
  });

  it("passes on the judged arm with a 60% win rate and a p50 within 10%", () => {
    const baseline = sideNumbers([sample("a", 20_000)]);
    const challenger = sideNumbers([sample("a", 21_000)]);

    assert.equal(applyDecisionRule(baseline, challenger, 0.6).passes, true);
    assert.equal(applyDecisionRule(baseline, challenger, 0.59).passes, false);
  });

  it("fails when a case passes less often than on the baseline", () => {
    const baseline = sideNumbers([sample("a", 20_000), sample("b", 20_000)]);
    const challenger = sideNumbers([sample("a", 10_000), sample("b", 10_000, "gpt-6.1-sol", false)]);

    assert.equal(applyDecisionRule(baseline, challenger, null).passCountsHold, false);
  });

  it("sums the challenger's wins over decided calls across groups", () => {
    const summaries = [
      { challenger: "kernel", total: { challengerWins: 3, baselineWins: 1 } },
      { challenger: "kernel", total: { challengerWins: 1, baselineWins: 3 } },
      { challenger: "other", total: { challengerWins: 9, baselineWins: 0 } },
    ];

    assert.equal(winRateFromSummary(summaries, "kernel"), 0.5);
    assert.equal(winRateFromSummary(summaries, "missing"), null);
  });
});
