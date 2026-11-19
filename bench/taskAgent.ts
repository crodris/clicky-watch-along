// Benchmark of the task agent, the one model call bench.ts does not cover. The agent's loop runs in the Go harness, so this
// drives the built harness binary over its stdin and stdout protocol, once per run, against Workers that each run the agent
// on a different Claude model (started with --var BENCH_MODEL:claude-<model>, see bench/README.md).
//
//   node bench/taskAgent.ts --harness bench/.harness/clicky-agent-harness --label agent --runs 2 \
//     --side base:8791 --side haiku:8792 --side sonnet:8793 --side opus:8794 --side fable:8795
//
// Results go to bench/results/<label>-<side>-task-agent-<sha>.json, and every full answer to --out-dir.

import { execFileSync, spawn } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseDevVars } from "./judgeModels.ts";
import { costOfUsageLine, isRecord, type UsageLine } from "./usage.ts";

const benchDirectory = dirname(fileURLToPath(import.meta.url));
const checkoutRoot = dirname(benchDirectory);

/** Each goal needs web search and nothing from Chrome, so the agent can finish with only the tools this driver answers. */
export const taskGoals: Array<{ id: string; goal: string }> = [
  { id: "starship-tower", goal: "find out how tall the Starship launch tower at Starbase is" },
  { id: "booster-catch", goal: "find out how the most recent Starship booster catch compares to the first booster catch" },
  { id: "webb-mirror", goal: "find out what the James Webb Space Telescope's mirror is made of and why" },
];

/** What the harness reports for one turn, read from the line `usageLine` writes in harness/loop.go. */
export type TaskTurn = {
  turn: number;
  stopReason: string;
  inputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  outputTokens: number;
};

// Matches harness/loop.go: "Task agent: turn %d stopped for %s, tokens in %d, cache read %d, cache write %d, out %d".
const tokenLinePattern = /^Task agent: turn (\d+) stopped for (\S*), tokens in (\d+), cache read (\d+), cache write (\d+), out (\d+)$/;

/** Null for any other log line, so a changed line shows up as a run with no turns instead of a wrong number. */
export function parseTokenLine(logMessage: string): TaskTurn | null {
  const lineMatch = tokenLinePattern.exec(logMessage);
  if (lineMatch === null) {
    return null;
  }
  return {
    turn: Number(lineMatch[1]),
    stopReason: lineMatch[2],
    inputTokens: Number(lineMatch[3]),
    cacheReadTokens: Number(lineMatch[4]),
    cacheWriteTokens: Number(lineMatch[5]),
    outputTokens: Number(lineMatch[6]),
  };
}

/** Prices the turns with the bench's own table. Web search and fetch fees are not token costs, so they are not in it. */
export function costOfTurns(model: string, turns: TaskTurn[]): number | null {
  let totalCost = 0;
  for (const turn of turns) {
    const usageLine: UsageLine = {
      route: "/v1/messages",
      model,
      serviceTier: undefined,
      inputTokens: turn.inputTokens,
      cacheWriteTokens: turn.cacheWriteTokens,
      cacheReadTokens: turn.cacheReadTokens,
      outputTokens: turn.outputTokens,
    };
    const turnCost = costOfUsageLine(usageLine);
    if (turnCost === null) {
      return null;
    }
    totalCost += turnCost;
  }
  return totalCost;
}

/** What the app would answer, so the agent can finish without Chrome, Notion, or a video. */
export function appToolAnswer(toolName: string): { content: string; isError: boolean } {
  switch (toolName) {
    case "report_step":
      return { content: "shown", isError: false };
    case "read_video_captions":
    case "look_at_video":
      return { content: "no video is open in this test", isError: true };
    case "write_notion_page":
      return { content: "Notion is off in this test", isError: true };
    default:
      return { content: `${toolName} is not available in this test`, isError: true };
  }
}

export type TaskRun = {
  side: string;
  model: string;
  taskId: string;
  goal: string;
  runIndex: number;
  outcome: "finished" | "failed";
  /** The agent's spoken summary when finished, else why it failed. */
  detail: string;
  totalMs: number;
  /** From sending start_task to the first tool_call or log line, which the harness sends after the first turn's reply ends. */
  firstOutputMs: number | null;
  turns: TaskTurn[];
  inputTokens: number;
  cacheWriteTokens: number;
  cacheReadTokens: number;
  outputTokens: number;
  costUSD: number | null;
  toolCalls: Array<{ name: string; input: unknown }>;
  logLines: string[];
};

function percentile(sortedValues: number[], fraction: number): number {
  if (sortedValues.length === 0) {
    return NaN;
  }
  const rank = Math.min(sortedValues.length - 1, Math.max(0, Math.ceil(fraction * sortedValues.length) - 1));
  return sortedValues[rank];
}

const mean = (values: number[]) => (values.length === 0 ? 0 : values.reduce((sum, value) => sum + value, 0) / values.length);

/**
 * One side's numbers. Time is over finished runs only, since a run that fails at once would otherwise look fast. Turns,
 * tokens, and cost are over every run, since a failed run still spent them. One unpriced run makes the mean cost unknown.
 */
export function summarizeTaskRuns(runs: TaskRun[]) {
  const finishedRuns = runs.filter((run) => run.outcome === "finished");
  const sortedTotals = finishedRuns.map((run) => run.totalMs).sort((smaller, larger) => smaller - larger);
  const sortedFirstOutputs = runs.flatMap((run) => (run.firstOutputMs === null ? [] : [run.firstOutputMs])).sort((smaller, larger) => smaller - larger);
  return {
    runs: runs.length,
    finished: finishedRuns.length,
    totalMs: { p50: Math.round(percentile(sortedTotals, 0.5)), p95: Math.round(percentile(sortedTotals, 0.95)) },
    firstOutputMsP50: Math.round(percentile(sortedFirstOutputs, 0.5)),
    meanTurns: Number(mean(runs.map((run) => run.turns.length)).toFixed(2)),
    meanInputTokens: Math.round(mean(runs.map((run) => run.inputTokens))),
    meanCacheWriteTokens: Math.round(mean(runs.map((run) => run.cacheWriteTokens))),
    meanCacheReadTokens: Math.round(mean(runs.map((run) => run.cacheReadTokens))),
    meanOutputTokens: Math.round(mean(runs.map((run) => run.outputTokens))),
    meanCostUSD: runs.some((run) => run.costUSD === null) ? null : Number(mean(runs.map((run) => run.costUSD ?? 0)).toFixed(5)),
  };
}

// The model each side name stands for when the side spec gives none, since the harness log does not name the model.
const modelsBySideName: Record<string, string> = {
  base: "claude-sonnet-5-5",
  sonnet: "claude-sonnet-5-5",
  haiku: "claude-haiku-5-5",
  opus: "claude-opus-5-5",
  fable: "claude-fable-5-2",
};

export type TaskSide = { name: string; port: number; model: string };

/** A side is name:port, or name:port:model when the name is not one of base, sonnet, haiku, opus, or fable. */
export function parseSideSpec(sideSpec: string): TaskSide {
  const [name, portText, modelOverride] = sideSpec.split(":");
  const port = Number(portText);
  const model = modelOverride ?? modelsBySideName[name];
  if (!name || !Number.isInteger(port) || port <= 0 || model === undefined) {
    throw new Error(`Side "${sideSpec}" must be name:port, with name one of ${Object.keys(modelsBySideName).join(", ")}, or name:port:model.`);
  }
  return { name, port, model };
}

type HarnessCommand = { command: string; args: string[] };

const taskTimeoutMs = 10 * 60 * 1000;

/** Runs one task on a fresh harness process and records how it ended. Never rejects: any failure is an outcome. */
export function driveTask(
  harness: HarnessCommand,
  side: TaskSide,
  appSecret: string,
  task: { id: string; goal: string },
  runIndex: number,
): Promise<TaskRun> {
  return new Promise((resolve) => {
    // A minimal environment, as the app gives the harness: none of this machine's Anthropic credentials reach the Worker.
    const harnessProcess = spawn(harness.command, harness.args, {
      env: { CLICKY_WORKER_BASE_URL: `http://127.0.0.1:${side.port}`, CLICKY_APP_SECRET: appSecret, PATH: "/usr/bin:/bin" },
      stdio: ["pipe", "pipe", "pipe"],
    });
    const taskID = `bench-${side.name}-${task.id}-${runIndex}`;
    const turns: TaskTurn[] = [];
    const toolCalls: TaskRun["toolCalls"] = [];
    const logLines: string[] = [];
    let stderrText = "";
    // Reset when the harness says ready, so a harness that dies first still reports a sane time.
    let startedAt = performance.now();
    let firstOutputMs: number | null = null;
    let isDone = false;

    const finish = (outcome: TaskRun["outcome"], detail: string) => {
      if (isDone) {
        return;
      }
      isDone = true;
      const totalMs = performance.now() - startedAt;
      clearTimeout(timeoutHandle);
      harnessProcess.stdin.end();
      setTimeout(() => harnessProcess.kill(), 2000).unref();
      resolve({
        side: side.name,
        model: side.model,
        taskId: task.id,
        goal: task.goal,
        runIndex,
        outcome,
        detail,
        totalMs,
        firstOutputMs,
        turns,
        inputTokens: turns.reduce((sum, turn) => sum + turn.inputTokens, 0),
        cacheWriteTokens: turns.reduce((sum, turn) => sum + turn.cacheWriteTokens, 0),
        cacheReadTokens: turns.reduce((sum, turn) => sum + turn.cacheReadTokens, 0),
        outputTokens: turns.reduce((sum, turn) => sum + turn.outputTokens, 0),
        costUSD: costOfTurns(side.model, turns),
        toolCalls,
        logLines,
      });
    };

    const send = (message: Record<string, unknown>) => {
      if (!harnessProcess.stdin.destroyed) {
        harnessProcess.stdin.write(`${JSON.stringify(message)}\n`);
      }
    };
    const timeoutHandle = setTimeout(() => finish("failed", `the driver gave up after ${taskTimeoutMs / 1000} s`), taskTimeoutMs);

    harnessProcess.stderr.on("data", (chunk: Buffer) => {
      stderrText = (stderrText + chunk.toString()).slice(-500);
    });
    harnessProcess.on("error", (error) => finish("failed", `the harness did not start: ${error.message}`));
    // "close", not "exit", so the stderr tail is read before the failure is recorded.
    harnessProcess.on("close", (exitCode) =>
      finish("failed", `the harness exited with code ${exitCode} before the task ended. stderr tail: ${stderrText.split(appSecret).join("[secret]")}`),
    );

    createInterface({ input: harnessProcess.stdout }).on("line", (line) => {
      let message: unknown;
      try {
        message = JSON.parse(line);
      } catch {
        finish("failed", `the harness wrote a line that is not JSON: ${line.slice(0, 200)}`);
        return;
      }
      if (!isRecord(message) || typeof message.type !== "string") {
        return;
      }
      if (message.type !== "ready" && firstOutputMs === null && (message.type === "tool_call" || message.type === "log")) {
        firstOutputMs = performance.now() - startedAt;
      }
      switch (message.type) {
        case "ready":
          startedAt = performance.now();
          send({ type: "start_task", taskID, goal: task.goal, frontTabTitle: null, frontTabURL: null });
          break;
        case "log": {
          const logMessage = String(message.message);
          logLines.push(logMessage);
          const turn = parseTokenLine(logMessage);
          if (turn !== null) {
            turns.push(turn);
          }
          break;
        }
        case "tool_call": {
          const toolName = String(message.name);
          toolCalls.push({ name: toolName, input: message.input });
          const answer = appToolAnswer(toolName);
          send({ type: "tool_result", taskID, toolUseID: message.toolUseID, content: answer.content, isError: answer.isError });
          break;
        }
        case "task_finished":
          finish("finished", String(message.spokenSummary));
          break;
        case "task_failed":
          finish("failed", String(message.reason));
          break;
      }
    });
  });
}

function commandLineOption(optionName: string): string | undefined {
  const optionIndex = process.argv.indexOf(`--${optionName}`);
  return optionIndex === -1 ? undefined : process.argv[optionIndex + 1];
}

function writeResultFile(label: string, sideName: string, result: Record<string, unknown>): string {
  const commitSHA = execFileSync("git", ["-C", checkoutRoot, "rev-parse", "--short=12", "HEAD"], { encoding: "utf8" }).trim();
  const workingTreeIsDirty =
    execFileSync("git", ["-C", checkoutRoot, "status", "--porcelain", "--", "worker", "harness", "leanring-buddy"], { encoding: "utf8" }).trim() !== "";
  const resultsDirectory = join(benchDirectory, "results");
  mkdirSync(resultsDirectory, { recursive: true });
  const resultPath = join(resultsDirectory, `${label}-${sideName}-task-agent-${commitSHA}.json`);
  writeFileSync(
    resultPath,
    `${JSON.stringify({ label, benchKind: "task-agent", commitSHA, workingTreeIsDirty, recordedAt: new Date().toISOString(), ...result }, null, 2)}\n`,
  );
  return resultPath;
}

async function main() {
  const harnessPath = commandLineOption("harness");
  const label = commandLineOption("label");
  const sideSpecs = process.argv.flatMap((argument, argumentIndex) => (process.argv[argumentIndex - 1] === "--side" ? [argument] : []));
  if (harnessPath === undefined || label === undefined || sideSpecs.length === 0) {
    console.error("Usage: node bench/taskAgent.ts --harness <clicky-agent-harness> --label <name> --side name:port [--side ...] [--runs 2] [--out-dir bench/replies/task-agent]");
    process.exit(2);
  }
  const sides = sideSpecs.map(parseSideSpec);
  const runCount = Number(commandLineOption("runs") ?? 2);
  const outDirectory = commandLineOption("out-dir") ?? join(benchDirectory, "replies", "task-agent");
  mkdirSync(outDirectory, { recursive: true });
  const appSecret = parseDevVars(readFileSync(join(checkoutRoot, "worker/.dev.vars"), "utf8")).CLICKY_APP_SECRET;
  if (appSecret === undefined || appSecret === "") {
    console.error("worker/.dev.vars has no CLICKY_APP_SECRET, so the Worker would answer 401 to the agent.");
    process.exit(2);
  }

  const runsBySide = new Map<string, TaskRun[]>(sides.map((side) => [side.name, []]));
  // Tasks run one at a time, and each task's runs alternate between sides, so upstream drift hits every side equally.
  for (const task of taskGoals) {
    for (let runIndex = 0; runIndex < runCount; runIndex++) {
      for (const side of sides) {
        const taskRun = await driveTask({ command: harnessPath, args: [] }, side, appSecret, task, runIndex);
        runsBySide.get(side.name)?.push(taskRun);
        writeFileSync(join(outDirectory, `${side.name}-${task.id}-${runIndex + 1}.json`), `${JSON.stringify(taskRun, null, 2)}\n`);
        console.log(
          `${side.name} ${task.id} #${runIndex + 1}: ${taskRun.outcome}, ${Math.round(taskRun.totalMs)} ms, ${taskRun.turns.length} turns` +
            (taskRun.outcome === "failed" ? `, ${taskRun.detail}` : ""),
        );
      }
    }
  }

  for (const side of sides) {
    const sideRuns = runsBySide.get(side.name) ?? [];
    const summary = summarizeTaskRuns(sideRuns);
    console.log(`${side.name} (${side.model})`);
    console.table({
      [side.name]: {
        p50: summary.totalMs.p50,
        p95: summary.totalMs.p95,
        firstOutputP50: summary.firstOutputMsP50,
        finished: `${summary.finished}/${summary.runs}`,
        meanTurns: summary.meanTurns,
        meanUSD: summary.meanCostUSD,
      },
    });
    const interleavedWith = sides.filter((otherSide) => otherSide !== side).map((otherSide) => otherSide.name);
    console.log(
      `saved ${writeResultFile(label, side.name, { model: side.model, port: side.port, runCount, interleavedWith, harness: harnessPath, summary, runs: sideRuns })}`,
    );
  }
  console.log(`full answers in ${outDirectory}`);
}

// taskAgent.test.ts imports the pure parts above and must not start a run.
if (import.meta.main) {
  await main();
}
