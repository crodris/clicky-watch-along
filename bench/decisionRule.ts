// Applies the decision rule in bench/README.md ("The decision rule") to a baseline and a challenger, from their result
// files and, for a route judged blind, the judge's summary.json. It drops a sample whose usage line names a model outside
// --allowed-models, such as a scene OpenAI could not answer that fell back to Sonnet, since it would measure the wrong model.
//
//   node bench/decisionRule.ts --baseline <result.json>[,<result.json>] --challenger <result.json>[,<result.json>]
//     [--allowed-models gpt-6.1-sol,gpt-6.2-sol] [--judge-summary <summary.json> --challenger-name kernel]
import { readFileSync } from "node:fs";

export type GateSample = {
  caseId: string;
  httpStatus: number;
  totalMs: number;
  costUSD: number | null;
  quality: { passed: boolean };
  usageLines: { model: string; outputTokens?: number }[];
};

export type SideNumbers = {
  samples: number;
  droppedSamples: number;
  p50Ms: number;
  p95Ms: number;
  meanCostUSD: number;
  meanOutputTokens: number;
  passedByCase: Record<string, number>;
  runsByCase: Record<string, number>;
};

export type GateVerdict = {
  baseline: SideNumbers;
  challenger: SideNumbers;
  passCountsHold: boolean;
  costHolds: boolean;
  fasterArm: boolean;
  judgedArm: boolean | null;
  winRate: number | null;
  passes: boolean;
};

/** The nearest-rank percentile bench.ts reports, so the gate reads the same p50 and p95 as the bench's table. */
export function nearestRankPercentile(values: number[], fraction: number): number {
  if (values.length === 0) return NaN;
  const sortedValues = [...values].sort((first, second) => first - second);
  return sortedValues[Math.min(sortedValues.length - 1, Math.max(0, Math.ceil(fraction * sortedValues.length) - 1))];
}

export function sampleUsesOnlyAllowedModels(sample: GateSample, allowedModels: string[] | undefined): boolean {
  if (allowedModels === undefined) return true;
  return sample.usageLines.length > 0 && sample.usageLines.every((usageLine) => allowedModels.some((model) => usageLine.model.startsWith(model)));
}

export function sideNumbers(samples: GateSample[], allowedModels?: string[]): SideNumbers {
  const kept = samples.filter((sample) => sampleUsesOnlyAllowedModels(sample, allowedModels));
  const mean = (values: number[]) => (values.length === 0 ? NaN : values.reduce((sum, value) => sum + value, 0) / values.length);
  const passedByCase: Record<string, number> = {};
  const runsByCase: Record<string, number> = {};
  for (const sample of kept) {
    passedByCase[sample.caseId] = (passedByCase[sample.caseId] ?? 0) + (sample.quality.passed ? 1 : 0);
    runsByCase[sample.caseId] = (runsByCase[sample.caseId] ?? 0) + 1;
  }
  return {
    samples: kept.length,
    droppedSamples: samples.length - kept.length,
    p50Ms: nearestRankPercentile(kept.map((sample) => sample.totalMs), 0.5),
    p95Ms: nearestRankPercentile(kept.map((sample) => sample.totalMs), 0.95),
    meanCostUSD: mean(kept.map((sample) => sample.costUSD ?? NaN)),
    meanOutputTokens: mean(kept.map((sample) => sample.usageLines.reduce((sum, usageLine) => sum + (usageLine.outputTokens ?? 0), 0))),
    passedByCase,
    runsByCase,
  };
}

/**
 * The rule, written before the runs: pass counts at least the baseline's on every case, cost at most 3 times the
 * baseline's or under $0.01, and either a p50 at least 25% lower with a p95 no worse, or a blind win rate of at least
 * 60% with a p50 within 10%. Pass counts compare shares, since a dropped sample leaves the sides with different counts.
 */
export function applyDecisionRule(baseline: SideNumbers, challenger: SideNumbers, winRate: number | null): GateVerdict {
  const passShare = (side: SideNumbers, caseId: string) => (side.passedByCase[caseId] ?? 0) / Math.max(1, side.runsByCase[caseId] ?? 0);
  const passCountsHold = Object.keys(baseline.runsByCase).every((caseId) => passShare(challenger, caseId) >= passShare(baseline, caseId));
  const costHolds = challenger.meanCostUSD <= baseline.meanCostUSD * 3 || challenger.meanCostUSD < 0.01;
  const fasterArm = challenger.p50Ms <= baseline.p50Ms * 0.75 && challenger.p95Ms <= baseline.p95Ms;
  const judgedArm = winRate === null ? null : winRate >= 0.6 && challenger.p50Ms <= baseline.p50Ms * 1.1;
  return { baseline, challenger, passCountsHold, costHolds, fasterArm, judgedArm, winRate, passes: passCountsHold && costHolds && (fasterArm || judgedArm === true) };
}

/** The challenger's wins over its decided calls, summed over every summary entry with that side name. */
export function winRateFromSummary(summaries: { challenger: string; total: { challengerWins: number; baselineWins: number } }[], challengerName: string): number | null {
  const matching = summaries.filter((summary) => summary.challenger === challengerName);
  const wins = matching.reduce((sum, summary) => sum + summary.total.challengerWins, 0);
  const losses = matching.reduce((sum, summary) => sum + summary.total.baselineWins, 0);
  return wins + losses === 0 ? null : wins / (wins + losses);
}

function samplesOf(resultPaths: string[]): GateSample[] {
  return resultPaths.flatMap((resultPath) => (JSON.parse(readFileSync(resultPath, "utf8")) as { samples: GateSample[] }).samples);
}

if (import.meta.main) {
  const option = (name: string) => {
    const index = process.argv.indexOf(`--${name}`);
    return index === -1 ? undefined : process.argv[index + 1];
  };
  const baselinePaths = option("baseline")?.split(",");
  const challengerPaths = option("challenger")?.split(",");
  if (baselinePaths === undefined || challengerPaths === undefined) {
    console.error("Usage: node bench/decisionRule.ts --baseline <result.json>[,...] --challenger <result.json>[,...] [--allowed-models a,b] [--judge-summary <summary.json> --challenger-name <side>]");
    process.exit(1);
  }
  const allowedModels = option("allowed-models")?.split(",");
  const judgeSummaryPath = option("judge-summary");
  const winRate = judgeSummaryPath === undefined ? null : winRateFromSummary(JSON.parse(readFileSync(judgeSummaryPath, "utf8")), option("challenger-name") ?? "");
  const verdict = applyDecisionRule(sideNumbers(samplesOf(baselinePaths), allowedModels), sideNumbers(samplesOf(challengerPaths), allowedModels), winRate);
  console.log(JSON.stringify(verdict, null, 2));
  console.log(verdict.passes ? "PASSES the decision rule" : "does not pass the decision rule");
}
