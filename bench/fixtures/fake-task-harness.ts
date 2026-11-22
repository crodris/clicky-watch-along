// A stand-in for the Go harness that speaks its protocol, so taskAgent.test.ts can drive the real driver without a Worker.
// It runs one turn that calls report_step, then finishes. Goals that start with "fail" end in task_failed instead.
import { createInterface } from "node:readline";

const write = (message: Record<string, unknown>) => process.stdout.write(`${JSON.stringify(message)}\n`);

if (process.env.CLICKY_WORKER_BASE_URL === undefined || process.env.CLICKY_APP_SECRET === undefined) {
  process.exit(3);
}
write({ type: "ready" });

let taskID = "";
let goal = "";
createInterface({ input: process.stdin }).on("line", (line) => {
  const message = JSON.parse(line);
  if (message.type === "start_task") {
    taskID = message.taskID;
    goal = message.goal;
    write({ type: "log", message: "Task agent: turn 1 stopped for tool_use, tokens in 100, cache read 2000, cache write 300, out 50" });
    write({ type: "tool_call", taskID, toolUseID: "call-1", name: "report_step", input: { text: "Searching" } });
  } else if (message.type === "tool_result") {
    write({ type: "log", message: "Task agent: turn 2 stopped for end_turn, tokens in 200, cache read 2500, cache write 0, out 70" });
    if (goal.startsWith("fail")) {
      write({ type: "task_failed", taskID, reason: `the answer to report_step was ${message.content}` });
    } else {
      write({ type: "task_finished", taskID, spokenSummary: `answered ${message.content}` });
    }
  }
});
