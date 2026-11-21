// A stand-in for the Go harness's voice command brain, so brainEvals.test.ts can drive the real process driver without a
// Worker. It speaks the lines of harness/brainloop.go. What a transcript makes it do:
//   "where"  calls find_moment in turn 0 and, once the app answers, seek_to_time in turn 1, then finishes with the
//            lookup's result text and the last outcome as its spoken line.
//   "say"    answers in words with no tool.
//   "fail"   ends in task_failed.
//   "both"   calls pop_out and then close_scene in turn 0, whose turn line names both. Only the first reaches the app, as
//            a hand-off ends the turn before the second.
//   "hang"   writes turn 1 only after 300 ms, as a slow Claude reply would. A cancel_task stops that, then writes two lines
//            the command had already queued, 10 ms apart, and logs the cancel 40 ms in, so a driver that stops reading
//            at the first stray line lets the second one reach the next command.
//   other    calls rotate_model once.
// Every command but "hang" is answered 30 ms after it arrives, so the stray lines above land while the next command waits.
// A command that ends after a tool finishes with the outcome and text the app answered.
// It takes reset_session and seed_session only with CLICKY_BENCH=1, as the real harness does, and says what it took in a
// log line (the real harness writes nothing), so a test can see which lines the driver sent before a command.
import { createInterface } from "node:readline";
import { isRecord } from "../usage.ts";

const write = (message: Record<string, unknown>) => process.stdout.write(`${JSON.stringify(message)}\n`);
const turnLine = (turn: number, inputTokens: number, outputTokens: number, calls: string) =>
  write({ type: "log", message: `Brain: turn ${turn} on claude-haiku-5-5 stopped for tool_use, tokens in ${inputTokens}, cache read 2000, cache write 0, out ${outputTokens}, 120 ms, calls ${calls}` });

if (process.env.CLICKY_WORKER_BASE_URL === undefined || process.env.CLICKY_APP_SECRET === undefined) {
  process.exit(3);
}
write({ type: "ready" });

let commandID = "";
let lookupContent = "";
let lateTurnTimer: ReturnType<typeof setTimeout> | undefined;
createInterface({ input: process.stdin }).on("line", (line) => {
  const message: unknown = JSON.parse(line);
  if (!isRecord(message)) {
    return;
  }
  if (message.type === "voice_command" && typeof message.taskID === "string" && typeof message.transcript === "string") {
    const voiceCommand = { taskID: message.taskID, transcript: message.transcript };
    setTimeout(() => answerCommand(voiceCommand), voiceCommand.transcript.includes("hang") ? 0 : 30);
  } else if (message.type === "reset_session" || message.type === "seed_session") {
    const taken = process.env.CLICKY_BENCH === "1";
    const seededCount = Array.isArray(message.messages) ? message.messages.length : 0;
    const interruptedCount = Array.isArray(message.interruptedBefore) ? message.interruptedBefore.length : 0;
    write({
      type: "log",
      message: taken ? `Fake: ${message.type}${message.type === "seed_session" ? ` ${seededCount} messages, ${interruptedCount} interrupted` : ""}` : `Fake: ignored ${message.type}`,
    });
  } else if (message.type === "cancel_task") {
    clearTimeout(lateTurnTimer);
    turnLine(1, 777, 777, "none");
    setTimeout(() => turnLine(1, 777, 777, "none"), 10);
    setTimeout(() => write({ type: "log", message: "Brain: command cancelled during turn 1" }), 40);
  } else if (message.type === "tool_result" && typeof message.outcome === "string" && typeof message.content === "string") {
    answerToolResult({ outcome: message.outcome, content: message.content });
  }
});

function answerCommand(message: { taskID: string; transcript: string }) {
  commandID = message.taskID;
  if (message.transcript.includes("hang")) {
    lateTurnTimer = setTimeout(() => turnLine(1, 999, 999, "none"), 300);
  } else if (message.transcript.includes("fail")) {
    turnLine(1, 100, 50, "none");
    write({ type: "task_failed", taskID: commandID, reason: "the request to Claude failed" });
  } else if (message.transcript.includes("say")) {
    turnLine(1, 100, 50, "none");
    write({ type: "voice_command_finished", taskID: commandID, spokenLine: "it is a shark", gaveUp: false });
  } else if (message.transcript.includes("where")) {
    turnLine(1, 100, 50, "find_moment");
    write({ type: "tool_call", taskID: commandID, toolUseID: "call-1", name: "find_moment", input: { query: "swim bladder" }, turnIndex: 0 });
  } else if (message.transcript.includes("both")) {
    turnLine(1, 100, 50, "pop_out,close_scene");
    write({ type: "tool_call", taskID: commandID, toolUseID: "call-1", name: "pop_out", input: {}, turnIndex: 0 });
  } else {
    turnLine(1, 100, 50, "rotate_model");
    write({ type: "tool_call", taskID: commandID, toolUseID: "call-1", name: "rotate_model", input: { yawDegrees: 45 }, turnIndex: 0 });
  }
}

function answerToolResult(message: { outcome: string; content: string }) {
  if (message.outcome === "lookedUp") {
    lookupContent = message.content;
    turnLine(2, 200, 70, "seek_to_time");
    write({ type: "tool_call", taskID: commandID, toolUseID: "call-2", name: "seek_to_time", input: { seconds: 98 }, turnIndex: 1 });
  } else {
    write({ type: "voice_command_finished", taskID: commandID, spokenLine: `${lookupContent}${message.outcome} ${message.content}`, gaveUp: false });
  }
}
