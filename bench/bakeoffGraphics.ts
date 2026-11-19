// Reads the 2026-11-19 bakeoff's result files and writes the numbers the cards in bench/graphics/ draw.
//
//   node bench/bakeoffGraphics.ts
//
// Writes bench/graphics/bakeoff-data.js, which sets window.bakeoff, since a card opened from file:// cannot fetch JSON.
// The blind judge's tallies are copied in below, because bench/replies/ (where judge.ts writes them) is gitignored.

import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { costOfUsageLine, type UsageLine } from "./usage.ts";

const resultsFolder = join(import.meta.dirname, "results");

type Sample = {
  httpStatus: number;
  totalMs: number;
  firstByteMs: number | null;
  firstTokenMs: number | null;
  usageLines: UsageLine[];
  quality?: { passed: boolean };
};
type WorkerResult = { summary: Array<{ route: string }>; samples: Sample[] };
type TaskAgentResult = { summary: { runs: number; finished: number; totalMs: { p50: number; p95: number }; meanCostUSD: number } };

export type ModelStats = {
  passed: number;
  runs: number;
  p50Ms: number;
  p95Ms: number;
  /** Time to the first streamed token, only for /chat. */
  firstTokenP50Ms: number | null;
  /** Mean over the calls whose cost is known. A call that never answered has none, since the vendor may still bill it. */
  costPerCallUSD: number;
};

/** The lower median, which is what the bakeoff report tables used. */
function lowerMedian(values: number[]): number {
  const sorted = [...values].sort((first, second) => first - second);
  return sorted[Math.floor((sorted.length - 1) / 2)] ?? Number.NaN;
}

function percentile95(values: number[]): number {
  const sorted = [...values].sort((first, second) => first - second);
  return sorted[Math.min(sorted.length - 1, Math.ceil(0.95 * sorted.length) - 1)] ?? Number.NaN;
}

function readResultFile<ResultShape>(fileNamePrefix: string): ResultShape {
  const fileName = readdirSync(resultsFolder).find((candidate) => candidate.startsWith(fileNamePrefix));
  if (fileName === undefined) {
    throw new Error(`No result file starts with ${fileNamePrefix}`);
  }
  // bench.ts and taskAgent.ts wrote these files, and report.ts reads them with the same trust.
  return JSON.parse(readFileSync(join(resultsFolder, fileName), "utf8")) as ResultShape;
}

/** The four route groups ran at once and shared each Worker's log, so a sample's cost counts only its own route's lines. */
function sampleCostUSD(sample: Sample, route: string): number | null {
  const ownLines = sample.usageLines.filter((usageLine) => usageLine.route === route);
  if (ownLines.length === 0) {
    return null;
  }
  let totalUSD = 0;
  for (const usageLine of ownLines) {
    const lineUSD = costOfUsageLine(usageLine);
    if (lineUSD === null) {
      return null;
    }
    totalUSD += lineUSD;
  }
  return totalUSD;
}

function workerStats(fileNamePrefix: string): ModelStats {
  const result = readResultFile<WorkerResult>(fileNamePrefix);
  const route = result.summary[0]?.route ?? "";
  const answered = result.samples.filter((sample) => sample.httpStatus === 200);
  const knownCosts = result.samples.map((sample) => sampleCostUSD(sample, route)).filter((costUSD) => costUSD !== null);
  return {
    passed: result.samples.filter((sample) => sample.quality?.passed === true).length,
    runs: result.samples.length,
    p50Ms: lowerMedian(answered.map((sample) => sample.totalMs)),
    p95Ms: percentile95(answered.map((sample) => sample.totalMs)),
    firstTokenP50Ms: route === "/chat" ? lowerMedian(answered.map((sample) => sample.firstTokenMs ?? sample.totalMs)) : null,
    costPerCallUSD: knownCosts.reduce((sum, costUSD) => sum + costUSD, 0) / Math.max(1, knownCosts.length),
  };
}

function taskAgentStats(side: string): ModelStats {
  const { summary } = readResultFile<TaskAgentResult>(`agent-${side}-task-agent-`);
  return {
    passed: summary.finished,
    runs: summary.runs,
    p50Ms: summary.totalMs.p50,
    p95Ms: summary.totalMs.p95,
    firstTokenP50Ms: null,
    costPerCallUSD: summary.meanCostUSD,
  };
}

const flagshipSides = ["base", "haiku", "sonnet", "opus", "fable", "sol62", "astra"] as const;

/** Each call the bench measures, with the result label of the six-challenger run and of the Neon run. */
const calls = [
  { key: "quiz", name: "Quiz plan", route: "/video-quiz-plan", neonLabel: "nquiz" },
  { key: "flows", name: "Picture flows", route: "/picture-flows", neonLabel: "nflows" },
  { key: "judge", name: "Answer grading", route: "/judge-answer", neonLabel: "njudge" },
  { key: "voice", name: "Voice commands", route: "/voice-command", neonLabel: "nvoice" },
  { key: "landmark", name: "Landmark lookup", route: "/landmark", neonLabel: "nlandmark" },
  { key: "parts", name: "Pop-out parts", route: "/video-frame-parts", neonLabel: "nparts" },
  { key: "chat", name: "Voice reply", route: "/chat", neonLabel: "nchat" },
] as const;

const routeStats = calls.map((call) => ({
  ...call,
  sides: Object.fromEntries(flagshipSides.map((side) => [side, workerStats(`${call.key}-${side}-worker-`)])),
  // Neon ran on its own, beside a fresh base, so its ratios are against that base.
  neon: { base: workerStats(`${call.neonLabel}-base-worker-`), neon: workerStats(`${call.neonLabel}-neon-worker-`) },
}));

const taskAgent = Object.fromEntries(["base", "haiku", "sonnet", "opus", "fable"].map((side) => [side, taskAgentStats(side)]));

const flowsRerun = Object.fromEntries(["base", "sonnet", "opus", "sol62"].map((side) => [side, workerStats(`flows2-${side}-worker-`)]));

/** Render round two: the app's GPT-6.1 Sol and the two GPT-6.2 models, all at Ultrafast, 2 runs of 3 cases. */
const renderRound2 = Object.fromEntries(["app", "sol62", "astra"].map((side) => [side, workerStats(`render2-${side}-worker-`)]));

/** Render round one: every model once on 3 cases. GPT sides other than app ran at the standard tier. */
const renderRound1 = Object.fromEntries(
  ["app", "base", "haiku", "sonnet", "opus", "fable", "sol62", "astra", "neon"].map((side) => [side, workerStats(`render1-${side}-worker-`)]),
);

type CaseSample = Sample & { caseId: string };

/** Each experiment's build times on GPT-6.1 Sol (the app) and GPT-6.2 Sol, from round two and the five-experiment run. */
function experimentTimes(side: "app" | "sol62"): Record<string, number[]> {
  const timesByExperiment: Record<string, number[]> = {};
  for (const label of ["render2", "sim3"]) {
    for (const sample of readResultFile<{ samples: CaseSample[] }>(`${label}-${side}-worker-`).samples) {
      if (sample.caseId.startsWith("simulation-") && sample.httpStatus === 200) {
        (timesByExperiment[sample.caseId] ??= []).push(sample.totalMs);
      }
    }
  }
  return timesByExperiment;
}
const experiments = { app: experimentTimes("app"), sol62: experimentTimes("sol62") };

/**
 * Blind judge tallies: wins and losses count one per judge per pair, and a pair a judge split across the A/B orders is
 * undecided. From bench/replies/judged/summary.json of the six-challenger and Neon runs, and the 5-run flows rerun.
 */
const blindJudge = {
  "/video-quiz-plan": { haiku: [2, 2], sonnet: [2, 2], opus: [1, 0], fable: [1, 2], sol62: [2, 0], astra: [1, 2], neon: [0, 2] },
  "/video-frame-parts": { haiku: [0, 12], sonnet: [7, 2], opus: [3, 6], fable: [5, 5], sol62: [5, 4], astra: [6, 2], neon: [5, 3] },
  "/picture-flows": { haiku: [1, 4], sonnet: [3, 2], opus: [1, 3], fable: [4, 0], sol62: [4, 1], astra: [3, 2], neon: [4, 1] },
  "/chat": { haiku: [3, 0], sonnet: [0, 3], opus: [3, 1], fable: [3, 0], sol62: [3, 0], astra: [4, 0], neon: [4, 0] },
  flowsRerun: { opus: [12, 8], sonnet: [17, 10], sol62: [21, 6] },
  // Against the app's GPT-6.1 Sol at Ultrafast, from bench/replies/render2/judged and render/judged-vs-app.
  renderRound2: { astra: [11, 0], sol62: [7, 4] },
  renderRound1: { astra: [6, 0], sol62: [5, 0], fable: [2, 0], neon: [2, 2], opus: [2, 4], sonnet: [2, 4], haiku: [1, 5], base: [1, 5] },
  // GPT-6.2 Sol against the app's GPT-6.1 Sol per experiment, from render2/judged and sim3/judged, as [6.2 Sol, 6.1 Sol].
  experiments: {
    "simulation-projectile": [4, 2],
    "simulation-lever": [5, 0],
    "simulation-pendulum": [2, 0],
    "simulation-dissolving": [2, 0],
    "simulation-cooling": [1, 0],
  },
};

const bakeoff = { recordedOn: "2026-11-19", routes: routeStats, taskAgent, flowsRerun, renderRound1, renderRound2, experiments, blindJudge };
const outputPath = join(import.meta.dirname, "graphics", "bakeoff-data.js");
writeFileSync(outputPath, `// Written by bench/bakeoffGraphics.ts. Do not edit by hand.\nwindow.bakeoff = ${JSON.stringify(bakeoff, null, 1)};\n`);
console.log(`wrote ${outputPath}`);
