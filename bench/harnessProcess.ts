// What taskAgent.ts and brainEvals.ts share to drive the built Go harness: the process with the environment the app gives
// it, the stderr tail with the app secret scrubbed out, and the reader of its stdout lines.

import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createInterface } from "node:readline";
import type { Readable } from "node:stream";
import { isRecord } from "./usage.ts";

export type HarnessCommand = { command: string; args: string[] };

const stderrTailLength = 500;

/**
 * Starts the harness with the minimum environment, as the app does, so none of this machine's Anthropic credentials reach
 * the Worker. `stderrTail` is the last 500 characters of its stderr with the app secret replaced, which is the only
 * place a driver may print stderr from. A write to a harness that already exited fails with an error event, which would
 * end the run with no result file, so the driver learns of it from the `close` event and the write's callback instead.
 */
export function spawnHarness(harness: HarnessCommand, workerPort: number, appSecret: string) {
  const harnessProcess: ChildProcessWithoutNullStreams = spawn(harness.command, harness.args, {
    env: { CLICKY_WORKER_BASE_URL: `http://127.0.0.1:${workerPort}`, CLICKY_APP_SECRET: appSecret, PATH: "/usr/bin:/bin" },
    stdio: ["pipe", "pipe", "pipe"],
  });
  // Kept longer than it is shown, so a secret that a chunk boundary splits is whole when it is scrubbed.
  let rawStderr = "";
  harnessProcess.stderr.on("data", (chunk: Buffer) => {
    rawStderr = (rawStderr + chunk.toString()).slice(-4 * stderrTailLength);
  });
  harnessProcess.stdin.on("error", () => {});
  return {
    harnessProcess,
    stderrTail: () => rawStderr.split(appSecret).join("[secret]").slice(-stderrTailLength),
  };
}

/** Calls `onMessage` for each stdout line that is a JSON object, and `onUnreadableLine` for a line that is not JSON. */
export function readJSONLines(stream: Readable, onMessage: (message: Record<string, unknown>) => void, onUnreadableLine?: (line: string) => void) {
  createInterface({ input: stream }).on("line", (line) => {
    let message: unknown;
    try {
      message = JSON.parse(line);
    } catch {
      onUnreadableLine?.(line);
      return;
    }
    if (isRecord(message)) {
      onMessage(message);
    }
  });
}
