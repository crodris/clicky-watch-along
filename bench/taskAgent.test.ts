import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import { appToolAnswer, costOfTurns, driveTask, parseSideSpec, parseTokenLine, summarizeTaskRuns, taskGoals, type TaskRun, type TaskTurn } from "./taskAgent.ts";

const benchDirectory = dirname(fileURLToPath(import.meta.url));

// Copied from the format string in harness/loop.go's usageLine, with numbers filled in.
const loopGoTokenLine = "Task agent: turn 3 stopped for end_turn, tokens in 1200, cache read 3400, cache write 56, out 789";

function taskRun(overrides: Partial<TaskRun>): TaskRun {
  return {
    side: "base",
    model: "claude-sonnet-5-5",
    taskId: "starship-tower",
    goal: "goal",
    runIndex: 0,
    outcome: "finished",
    detail: "",
    totalMs: 1000,
    firstOutputMs: 500,
    turns: [],
    inputTokens: 0,
    cacheWriteTokens: 0,
    cacheReadTokens: 0,
    outputTokens: 0,
    costUSD: 0,
    toolCalls: [],
    logLines: [],
    ...overrides,
  };
}

describe("parseTokenLine", () => {
  it("reads the line harness/loop.go writes for each turn", () => {
    assert.deepEqual(parseTokenLine(loopGoTokenLine), {
      turn: 3,
      stopReason: "end_turn",
      inputTokens: 1200,
      cacheReadTokens: 3400,
      cacheWriteTokens: 56,
      outputTokens: 789,
    });
  });

  it("ignores every other harness log line", () => {
    assert.equal(parseTokenLine("Task agent: finished in 12 s after 3 turns"), null);
    assert.equal(parseTokenLine("Task agent: turn 1 stopped for tool_use, tokens in x"), null);
  });

  it("still matches the format string in harness/loop.go, so a changed line fails here instead of reading as zero turns", () => {
    const loopSource = readFileSync(join(benchDirectory, "..", "harness", "loop.go"), "utf8");

    assert.ok(loopSource.includes('"Task agent: turn %d stopped for %s, tokens in %d, cache read %d, cache write %d, out %d"'));
  });
});

describe("costOfTurns", () => {
  it("sums each turn at the model's cache and output rates", () => {
    const turns: TaskTurn[] = [
      { turn: 1, stopReason: "tool_use", inputTokens: 1000, cacheReadTokens: 5000, cacheWriteTokens: 200, outputTokens: 300 },
      { turn: 2, stopReason: "end_turn", inputTokens: 500, cacheReadTokens: 6000, cacheWriteTokens: 0, outputTokens: 100 },
    ];

    const expectedCost = (1500 * 2 + 200 * 2.5 + 11000 * 0.1 + 400 * 10) / 1_000_000;
    assert.ok(Math.abs((costOfTurns("claude-sonnet-5-5", turns) ?? 0) - expectedCost) < 1e-9);
  });

  it("is unknown for a model with no price", () => {
    const originalWarn = console.warn;
    console.warn = () => {};
    try {
      const turns: TaskTurn[] = [{ turn: 1, stopReason: "end_turn", inputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 1 }];
      assert.equal(costOfTurns("claude-unpriced-9", turns), null);
    } finally {
      console.warn = originalWarn;
    }
  });
});

describe("summarizeTaskRuns", () => {
  it("takes time from finished runs only and tokens and cost from every run", () => {
    const summary = summarizeTaskRuns([
      taskRun({ totalMs: 10_000, inputTokens: 100, costUSD: 0.01 }),
      taskRun({ totalMs: 20_000, inputTokens: 300, costUSD: 0.03 }),
      taskRun({ outcome: "failed", totalMs: 50, firstOutputMs: null, inputTokens: 200, costUSD: 0.02 }),
    ]);

    assert.equal(summary.finished, 2);
    assert.equal(summary.totalMs.p50, 10_000);
    assert.equal(summary.totalMs.p95, 20_000);
    assert.equal(summary.firstOutputMsP50, 500);
    assert.equal(summary.meanInputTokens, 200);
    assert.equal(summary.meanCostUSD, 0.02);
  });

  it("makes the mean cost unknown when any run is unpriced", () => {
    assert.equal(summarizeTaskRuns([taskRun({ costUSD: 0.01 }), taskRun({ costUSD: null })]).meanCostUSD, null);
  });
});

describe("parseSideSpec", () => {
  it("names the model from the side name, or from a third field", () => {
    assert.deepEqual(parseSideSpec("opus:8794"), { name: "opus", port: 8794, model: "claude-opus-5-5" });
    assert.deepEqual(parseSideSpec("base:8791"), { name: "base", port: 8791, model: "claude-sonnet-5-5" });
    assert.deepEqual(parseSideSpec("mine:8800:claude-haiku-5-5"), { name: "mine", port: 8800, model: "claude-haiku-5-5" });
  });

  it("refuses a side it cannot price", () => {
    assert.throws(() => parseSideSpec("mystery:8800"));
    assert.throws(() => parseSideSpec("opus:notaport"));
  });
});

describe("the task list and the app's answers", () => {
  it("has three goals with distinct ids", () => {
    assert.equal(taskGoals.length, 3);
    assert.equal(new Set(taskGoals.map((task) => task.id)).size, 3);
  });

  it("shows steps and refuses what needs Chrome or Notion", () => {
    assert.deepEqual(appToolAnswer("report_step"), { content: "shown", isError: false });
    assert.equal(appToolAnswer("look_at_video").isError, true);
    assert.equal(appToolAnswer("read_video_captions").isError, true);
    assert.deepEqual(appToolAnswer("write_notion_page"), { content: "Notion is off in this test", isError: true });
  });
});

describe("driveTask", () => {
  const fakeHarness = { command: process.execPath, args: [join(benchDirectory, "fixtures", "fake-task-harness.ts")] };
  const side = { name: "base", port: 1, model: "claude-sonnet-5-5" };

  it("answers the agent's tool calls and records the finished run's turns, first output, and cost", async () => {
    const run = await driveTask(fakeHarness, side, "s3cret", { id: "t", goal: "find something" }, 0);

    assert.equal(run.outcome, "finished");
    assert.equal(run.detail, "answered shown");
    assert.equal(run.turns.length, 2);
    assert.equal(run.inputTokens, 300);
    assert.equal(run.cacheReadTokens, 4500);
    assert.equal(run.cacheWriteTokens, 300);
    assert.equal(run.outputTokens, 120);
    assert.deepEqual(run.toolCalls, [{ name: "report_step", input: { text: "Searching" } }]);
    assert.notEqual(run.firstOutputMs, null);
    assert.notEqual(run.costUSD, null);
  });

  it("records a task_failed as a failed run with its reason", async () => {
    const run = await driveTask(fakeHarness, side, "s3cret", { id: "t", goal: "fail please" }, 0);

    assert.equal(run.outcome, "failed");
    assert.equal(run.detail, "the answer to report_step was shown");
  });

  it("records a harness that dies before the task ends, with the secret scrubbed from its stderr", async () => {
    const dyingHarness = { command: process.execPath, args: ["-e", "console.error('boom s3cret'); process.exit(1)"] };

    const run = await driveTask(dyingHarness, side, "s3cret", { id: "t", goal: "x" }, 0);

    assert.equal(run.outcome, "failed");
    assert.match(run.detail, /exited with code 1/);
    assert.ok(run.detail.includes("boom [secret]"));
    assert.ok(!run.detail.includes("s3cret"));
  });
});
