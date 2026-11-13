// Turns benchmark result files into CSV tables for a chart page.
//
//   node bench/report.ts --out <folder> <result.json> [<result.json> ...]
//
// Writes routes.csv (one row per case and side), samples.csv (one row per request), and app.csv (app timings).

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const caseLabels: Record<string, string> = {
  "chat-first": "Voice reply, first question",
  "chat-followup": "Voice reply, follow-up",
  tts: "Speech for one reply",
  "video-quiz-plan": "Quiz plan, 3.5-min video",
  "video-quiz-plan-long": "Quiz plan, 10-min video",
  "frame-parts-heart": "Pop-out parts, diagram",
  "frame-parts-painting": "Pop-out parts, painting",
  landmark: "Landmark lookup",
  "live-scene": "3D live scene",
  "judge-correct": "Grade: correct answer",
  "judge-named-only": "Grade: name only",
  "judge-wrong": "Grade: wrong answer",
  "judge-help": "Grade: asks for help",
  "judge-function-only": "Grade: function only",
  "judge-caption-supported": "Grade: caption answer",
  "judge-caption-wrong": "Grade: caption, wrong",
};

type LatencySummary = { p50: number; p95: number; min: number; max: number };

type CaseSummary = {
  caseId: string;
  route: string;
  models: string[];
  runs: number;
  qualityPassed: number;
  totalMs: LatencySummary;
  firstTokenMs: LatencySummary | null;
  firstAudioMs?: LatencySummary | null;
  meanInputTokens: number;
  meanCacheWriteTokens: number;
  meanCacheReadTokens: number;
  meanOutputTokens: number;
  meanCostUSD: number;
};

type UsageLine = { inputTokens: number; cacheWriteTokens: number; cacheReadTokens: number; outputTokens: number };

type Sample = {
  caseId: string;
  runIndex: number;
  httpStatus: number;
  totalMs: number;
  firstTokenMs: number | null;
  firstAudioMs?: number | null;
  usageLines: UsageLine[];
  costUSD: number;
  ttsCharacters?: number;
  quality: { passed: boolean; detail: string };
  replyPreview?: string;
};

/** What a chat reply would speak: its text without the pointing tag. Null for other routes or older results. */
function spokenCharacters(sample: Sample): number | null {
  if (!sample.caseId.startsWith("chat") || sample.replyPreview === undefined) {
    return null;
  }
  return sample.replyPreview.replace(/\[POINT:[^\]]*\]/g, "").trim().length;
}

type WorkerResult = { label: string; benchKind: "worker"; commitSHA: string; summary: CaseSummary[]; samples: Sample[] };
type AppResult = {
  label: string;
  benchKind: "app";
  commitSHA: string;
  summary: { stepId: string; description: string; runs: number; elapsedMs: LatencySummary }[];
};

function csvCell(value: unknown): string {
  const text = value === null || value === undefined ? "" : String(value);
  return /[",\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

function csv(rows: Record<string, unknown>[]): string {
  const columns = Object.keys(rows[0] ?? {});
  return [columns.join(","), ...rows.map((row) => columns.map((column) => csvCell(row[column])).join(","))].join("\n") + "\n";
}

const round = (value: number | undefined | null) => (value === undefined || value === null ? null : Math.round(value));
const sumOfLines = (sample: Sample, pick: (usageLine: UsageLine) => number) =>
  sample.usageLines.reduce((runningSum, usageLine) => runningSum + pick(usageLine), 0);

const casesSamples = (workerResult: WorkerResult, caseId: string) => workerResult.samples.filter((sample) => sample.caseId === caseId);

function meanOrNull(values: (number | null)[]): number | null {
  const presentValues = values.filter((value): value is number => value !== null);
  return presentValues.length === 0 ? null : Math.round(presentValues.reduce((sum, value) => sum + value, 0) / presentValues.length);
}

function main() {
  const outIndex = process.argv.indexOf("--out");
  const outFolder = outIndex === -1 ? undefined : process.argv[outIndex + 1];
  const resultPaths = process.argv.slice(2).filter((argument, argumentIndex, all) => argument !== "--out" && all[argumentIndex - 1] !== "--out");
  if (outFolder === undefined || resultPaths.length === 0) {
    console.error("Usage: node bench/report.ts --out <folder> <result.json> [<result.json> ...]");
    process.exit(1);
  }
  const results: unknown[] = resultPaths.map((resultPath) => JSON.parse(readFileSync(resultPath, "utf8")));
  // Result files are this benchmark's own output, so their kind names their shape.
  const isResultOfKind = (result: unknown, benchKind: string) =>
    typeof result === "object" && result !== null && "benchKind" in result && result.benchKind === benchKind;
  const workerResults = results.filter((result): result is WorkerResult => isResultOfKind(result, "worker"));
  const appResults = results.filter((result): result is AppResult => isResultOfKind(result, "app"));

  const routeRows = workerResults.flatMap((workerResult) =>
    workerResult.summary.map((caseSummary) => ({
      case: caseSummary.caseId,
      label: caseLabels[caseSummary.caseId] ?? caseSummary.caseId,
      route: caseSummary.route,
      side: workerResult.label,
      commit: workerResult.commitSHA,
      models: caseSummary.models.join(" "),
      runs: caseSummary.runs,
      passed: caseSummary.qualityPassed,
      p50_ms: caseSummary.totalMs.p50,
      p95_ms: caseSummary.totalMs.p95,
      min_ms: caseSummary.totalMs.min,
      max_ms: caseSummary.totalMs.max,
      first_token_p50_ms: caseSummary.firstTokenMs?.p50 ?? null,
      first_audio_p50_ms: caseSummary.firstAudioMs?.p50 ?? null,
      input_tokens: caseSummary.meanInputTokens,
      cache_read_tokens: caseSummary.meanCacheReadTokens,
      cache_write_tokens: caseSummary.meanCacheWriteTokens,
      output_tokens: caseSummary.meanOutputTokens,
      cost_usd: caseSummary.meanCostUSD,
      tts_characters: caseSummary.route === "/tts" ? (casesSamples(workerResult, caseSummary.caseId)[0]?.ttsCharacters ?? null) : null,
      spoken_characters: meanOrNull(casesSamples(workerResult, caseSummary.caseId).map(spokenCharacters)),
    })),
  );

  const sampleRows = workerResults.flatMap((workerResult) =>
    workerResult.samples.map((sample) => ({
      side: workerResult.label,
      case: sample.caseId,
      run: sample.runIndex + 1,
      http_status: sample.httpStatus,
      total_ms: round(sample.totalMs),
      first_token_ms: round(sample.firstTokenMs),
      first_audio_ms: round(sample.firstAudioMs),
      model_calls: sample.usageLines.length,
      input_tokens: sumOfLines(sample, (usageLine) => usageLine.inputTokens),
      cache_read_tokens: sumOfLines(sample, (usageLine) => usageLine.cacheReadTokens),
      cache_write_tokens: sumOfLines(sample, (usageLine) => usageLine.cacheWriteTokens),
      output_tokens: sumOfLines(sample, (usageLine) => usageLine.outputTokens),
      cost_usd: Number(sample.costUSD.toFixed(5)),
      spoken_characters: spokenCharacters(sample),
      passed: sample.quality.passed,
      check: sample.quality.detail,
    })),
  );

  const appRows = appResults.flatMap((appResult) =>
    appResult.summary.map((stepSummary) => ({
      side: appResult.label,
      commit: appResult.commitSHA,
      step: stepSummary.stepId,
      what: stepSummary.description,
      runs: stepSummary.runs,
      p50_ms: stepSummary.elapsedMs.p50,
      p95_ms: stepSummary.elapsedMs.p95,
      min_ms: stepSummary.elapsedMs.min,
      max_ms: stepSummary.elapsedMs.max,
    })),
  );

  mkdirSync(outFolder, { recursive: true });
  writeFileSync(join(outFolder, "routes.csv"), csv(routeRows));
  writeFileSync(join(outFolder, "samples.csv"), csv(sampleRows));
  if (appRows.length > 0) {
    writeFileSync(join(outFolder, "app.csv"), csv(appRows));
  }
  console.log(`wrote ${routeRows.length} route rows, ${sampleRows.length} samples, ${appRows.length} app rows to ${outFolder}`);
}

main();
