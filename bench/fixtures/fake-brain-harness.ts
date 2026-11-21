// A stand-in for the Go harness's voice command brain, so brainEvals.test.ts can drive the real process driver without a
// Worker. It speaks the lines of harness/brainloop.go. A transcript with "where" calls find_moment in turn 0 and, once the
// app answers, seek_to_time in turn 1, then finishes with the lookup's result text and the last outcome as its spoken line. "say" answers in
// words with no tool, "fail" ends in task_failed, and anything else calls rotate_model once. A command that ends after a tool finishes with the outcome and text the app answered.
import { createInterface } from "node:readline";

const write = (message: Record<string, unknown>) => process.stdout.write(`${JSON.stringify(message)}\n`);
const turnLine = (turn: number, inputTokens: number, outputTokens: number) =>
  write({ type: "log", message: `Brain: turn ${turn} on claude-haiku-5-5 stopped for tool_use, tokens in ${inputTokens}, cache read 2000, cache write 0, out ${outputTokens}, 120 ms` });

if (process.env.CLICKY_WORKER_BASE_URL === undefined || process.env.CLICKY_APP_SECRET === undefined) {
  process.exit(3);
}
write({ type: "ready" });

let commandID = "";
let lookupContent = "";
createInterface({ input: process.stdin }).on("line", (line) => {
  const message = JSON.parse(line);
  if (message.type === "voice_command") {
    commandID = message.taskID;
    turnLine(1, 100, 50);
    if (message.transcript.includes("fail")) {
      write({ type: "task_failed", taskID: commandID, reason: "the request to Claude failed" });
    } else if (message.transcript.includes("say")) {
      write({ type: "voice_command_finished", taskID: commandID, spokenLine: "it is a shark", gaveUp: false });
    } else if (message.transcript.includes("where")) {
      write({ type: "tool_call", taskID: commandID, toolUseID: "call-1", name: "find_moment", input: { query: "swim bladder" }, turnIndex: 0 });
    } else {
      write({ type: "tool_call", taskID: commandID, toolUseID: "call-1", name: "rotate_model", input: { yawDegrees: 45 }, turnIndex: 0 });
    }
  } else if (message.type === "tool_result") {
    if (message.outcome === "lookedUp") {
      lookupContent = message.content;
      turnLine(2, 200, 70);
      write({ type: "tool_call", taskID: commandID, toolUseID: "call-2", name: "seek_to_time", input: { seconds: 98 }, turnIndex: 1 });
    } else {
      write({ type: "voice_command_finished", taskID: commandID, spokenLine: `${lookupContent}${message.outcome} ${message.content}`, gaveUp: false });
    }
  }
});
