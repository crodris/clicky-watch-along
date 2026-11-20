// Brain evals. Measure whether the Haiku voice command router behind POST /voice-command picks the right tool
// for what a learner says, so a model or prompt change cannot quietly change what Clicky does.
//
//   .claude/skills/verify-clicky/verify-clicky.sh worker-up 8797 -- --inspector-port 9307
//   node bench/brainEvals.ts run --label baseline [--runs 1] [--only caseId,...] [--port 8797] [--checkout <path>]
//   node bench/brainEvals.ts sync-tools
//
// The cases and the screen each one runs in are in fixtures/brain-evals.json. The tools the router is offered are in
// fixtures/brain-evals-tools.json, one descriptor per tool, as the app sends them. Results go to
// bench/results/<label>-brain-evals-<sha>.json. See "Brain evals" in bench/README.md.
//
// How a request is built. The app sends { messages, tools } to the Worker, which adds the model, the system prompt, and a
// `confirmation` property on every tool. `voiceCommandUserMessageText` mirrors the app's function of the same name in
// leanring-buddy/VoiceCommandTools.swift, and the tool list is the catalog filtered to the tools the context offers, in the
// app's order (page tools, then app tools in AppVoiceTool order). fixtures/voice-command*.json are real app request
// bodies, and brainEvals.test.ts pins that this file builds their messages byte for byte.
//
// How to regenerate the tool descriptors. The descriptions live in leanring-buddy/VoiceCommandTools.swift (app tools) and
// leanring-buddy/LiveSceneAssets/scene-tools.js (page tools). Run `node bench/brainEvals.ts sync-tools` after changing
// one, and the catalog's descriptions follow. Input schemas, `set_control` (whose description is built from the page's
// controls) and tools the source does not define yet (`handWritten` in the catalog) are edited in the catalog by hand.
// brainEvals.test.ts fails when a description in the catalog differs from its source.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { costOfUsageLine, isRecord, usageLinesOfRouteInLog, type UsageLine } from "./usage.ts";

const benchDirectory = dirname(fileURLToPath(import.meta.url));
const checkoutRoot = dirname(benchDirectory);
const casesPath = join(benchDirectory, "fixtures", "brain-evals.json");
const toolCatalogPath = join(benchDirectory, "fixtures", "brain-evals-tools.json");

// ---------- Fixture types ----------

export type ToolDescriptor = {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  readOnly: boolean;
  /** True for a tool the app source does not define yet, so `sync-tools` leaves its description alone. */
  handWritten?: boolean;
};

export type EvalContext = {
  description: string;
  /** The scene_state the app sends: the page's own state plus `page`, `video`, and `videoQuizIsRunning`. */
  sceneState: Record<string, unknown>;
  /** The tools the app offers in this context, by name. */
  tools: string[];
};

/** One acceptable set of tool calls: "none" for a plain spoken answer, a tool name, or several names called together. */
export type AcceptedAnswer = string | string[];

export type BrainCase = {
  id: string;
  context: string;
  /** The learner's words, as speech recognition would give them. */
  say: string;
  /** Any one of these counts as a pass. */
  accept: AcceptedAnswer[];
  /**
   * Input the called tools must carry, by tool name. Each key must match the call's input exactly, and `null` means
   * the key must be absent. Keys not listed are not checked, and a tool not listed is not checked at all.
   */
  input?: Record<string, Record<string, unknown>>;
  /** The router's recent tool call lines, as the app writes them, for a command that corrects the last action. */
  recentActions?: string[];
  /** Why the case exists, for the reader of a failure. */
  why: string;
};

export type BrainEvalFile = {
  /** The skills the app lists in start_background_task, as `TaskAgentSkillCatalog` reads them from its Skills folders. */
  skills?: SkillSummary[];
  contexts: Record<string, EvalContext>;
  cases: BrainCase[];
};

export type SkillSummary = { name: string; description: string };
export type ToolCatalog = { tools: ToolDescriptor[] };

// ---------- Request building ----------

/** The app's compact JSON: keys sorted at every level, no spaces. */
export function compactJSONText(value: unknown): string {
  const sortKeys = (node: unknown): unknown => {
    if (Array.isArray(node)) {
      return node.map(sortKeys);
    }
    if (isRecord(node)) {
      return Object.fromEntries(Object.keys(node).sort().map((key) => [key, sortKeys(node[key])]));
    }
    return node;
  };
  return JSON.stringify(sortKeys(value));
}

/** Mirrors voiceCommandUserMessageText in VoiceCommandTools.swift, including cutting every "<" out of the page's text. */
export function voiceCommandUserMessageText(learnerTranscript: string, sceneState: unknown, recentActionLines: string[]): string {
  const stateText = compactJSONText(sceneState).replaceAll("<", " ");
  const actionsText = recentActionLines.join("\n").replaceAll("<", " ");
  return `<scene_state>${stateText}</scene_state>\n<recent_actions>\n${actionsText}\n</recent_actions>\nLearner said: "${learnerTranscript}"`;
}

export function acceptedAnswersOf(brainCase: BrainCase): string[][] {
  return brainCase.accept.map((answer) => (answer === "none" ? [] : typeof answer === "string" ? [answer] : answer));
}

/** The sentence `descriptor(skills:)` in VoiceCommandTools.swift adds to start_background_task, kept here word for word. */
export const skillInstructionSentence =
  "Pass skill when the learner's request matches what one of these skills does, such as \"make flashcards from this video\". Leave skill out for any other task.";
/** The description `descriptor(skills:)` gives the `skill` input, kept here word for word. */
export const skillInputDescription = "The skill to run. Leave it out when no skill matches the request.";

/**
 * Mirrors `AppVoiceTool.descriptor(skills:)` in VoiceCommandTools.swift: with skills, start_background_task lists them in
 * its description and takes an optional `skill` input. Every other tool, and the tool with no skills, is unchanged.
 * `brainEvals.test.ts` checks that the app source holds the sentences used here.
 */
export function withSkills(tool: ToolDescriptor, skills: SkillSummary[]): ToolDescriptor {
  if (tool.name !== "start_background_task" || skills.length === 0) {
    return tool;
  }
  const skillLines = skills.map((skill) => `${skill.name}: ${skill.description}`).join("\n");
  const properties = isRecord(tool.inputSchema.properties) ? tool.inputSchema.properties : {};
  return {
    ...tool,
    description: `${tool.description}\nSkills, each a fixed procedure for one kind of task:\n${skillLines}\n${skillInstructionSentence}`,
    inputSchema: {
      ...tool.inputSchema,
      properties: {
        ...properties,
        skill: { type: "string", enum: skills.map((skill) => skill.name), description: skillInputDescription },
      },
    },
  };
}

/** The /voice-command body for one case: the app's message and the context's tools. */
export function requestBodyFor(brainCase: BrainCase, evalFile: BrainEvalFile, toolCatalog: ToolCatalog) {
  const context = evalFile.contexts[brainCase.context];
  const offeredToolNames = new Set(context.tools);
  return {
    messages: [{ role: "user", content: voiceCommandUserMessageText(brainCase.say, context.sceneState, brainCase.recentActions ?? []) }],
    tools: toolCatalog.tools
      .filter((tool) => offeredToolNames.has(tool.name))
      .map((tool) => withSkills(tool, evalFile.skills ?? []))
      .map(({ name, description, inputSchema, readOnly }) => ({ name, description, inputSchema, readOnly })),
  };
}

/** Throws a message naming the first problem, so a typo in a case fails at load and not as a silent wrong score. */
export function validateBrainEvals(evalFile: BrainEvalFile, toolCatalog: ToolCatalog): void {
  const catalogNames = new Set(toolCatalog.tools.map((tool) => tool.name));
  if (catalogNames.size !== toolCatalog.tools.length) {
    throw new Error("The tool catalog lists a tool name twice.");
  }
  for (const [contextName, context] of Object.entries(evalFile.contexts)) {
    for (const toolName of context.tools) {
      if (!catalogNames.has(toolName)) {
        throw new Error(`Context ${contextName} offers ${toolName}, which is not in brain-evals-tools.json.`);
      }
    }
    if (context.tools.length === 0 || context.tools.length > 40 || new Set(context.tools).size !== context.tools.length) {
      throw new Error(`Context ${contextName} must offer 1 to 40 different tools, since the Worker refuses anything else.`);
    }
  }
  const caseIds = new Set<string>();
  for (const brainCase of evalFile.cases) {
    if (caseIds.has(brainCase.id)) {
      throw new Error(`Case id ${brainCase.id} is used twice.`);
    }
    caseIds.add(brainCase.id);
    const context = evalFile.contexts[brainCase.context];
    if (context === undefined) {
      throw new Error(`Case ${brainCase.id} names the unknown context ${brainCase.context}.`);
    }
    if (brainCase.say.trim() === "" || brainCase.why.trim() === "" || brainCase.accept.length === 0) {
      throw new Error(`Case ${brainCase.id} needs say, why, and at least one accepted answer.`);
    }
    for (const toolName of acceptedAnswersOf(brainCase).flat()) {
      if (!context.tools.includes(toolName)) {
        throw new Error(`Case ${brainCase.id} accepts ${toolName}, which context ${brainCase.context} does not offer.`);
      }
    }
    for (const toolName of Object.keys(brainCase.input ?? {})) {
      if (!acceptedAnswersOf(brainCase).flat().includes(toolName)) {
        throw new Error(`Case ${brainCase.id} checks the input of ${toolName}, which no accepted answer calls.`);
      }
    }
  }
}

// ---------- Scoring ----------

export type Outcome =
  /** The tools called match an accepted answer. */
  | "pass"
  /** A tool was called, and no accepted answer is that tool or set of tools. */
  | "wrongTool"
  /** The tools match an accepted answer, but a call's input differs from the case's expected input. */
  | "wrongInput"
  /** No tool was called, and every accepted answer holds a tool. */
  | "missedTool"
  /** A tool was called, and the only accepted answer is a plain spoken reply. */
  | "spuriousTool"
  /** The Worker did not answer with a reply. */
  | "error";

export type ToolCall = { name: string; input: Record<string, unknown> };

export function toolCallsIn(replyText: string): { toolCalls: ToolCall[]; spokenText: string } {
  let parsedReply: unknown;
  try {
    parsedReply = JSON.parse(replyText);
  } catch {
    parsedReply = undefined;
  }
  const content = isRecord(parsedReply) ? parsedReply.content : undefined;
  const blocks = (Array.isArray(content) ? content : []).filter(isRecord);
  return {
    toolCalls: blocks
      .filter((block) => block.type === "tool_use")
      .map((block) => ({ name: String(block.name), input: isRecord(block.input) ? block.input : {} })),
    spokenText: blocks.flatMap((block) => (block.type === "text" ? [String(block.text)] : [])).join(" "),
  };
}

const sameToolSet = (calledToolNames: string[], acceptedToolNames: string[]) =>
  calledToolNames.length === acceptedToolNames.length && calledToolNames.every((toolName) => acceptedToolNames.includes(toolName));

/** Scores the tools one reply called against the case's accepted answers. The order and repeats of calls do not matter. */
export function scoreToolCalls(calledToolNames: string[], acceptedAnswers: string[][]): Exclude<Outcome, "error"> {
  const calledSet = [...new Set(calledToolNames)];
  if (acceptedAnswers.some((acceptedAnswer) => sameToolSet(calledSet, [...new Set(acceptedAnswer)]))) {
    return "pass";
  }
  if (calledSet.length === 0) {
    return "missedTool";
  }
  return acceptedAnswers.every((acceptedAnswer) => acceptedAnswer.length === 0) ? "spuriousTool" : "wrongTool";
}

/** Whether a call's input holds the expected keys. A `null` expected value means the key must be absent. */
function inputMatches(callInput: Record<string, unknown>, expectedInput: Record<string, unknown>): boolean {
  return Object.entries(expectedInput).every(([key, expectedValue]) =>
    expectedValue === null ? !(key in callInput) : JSON.stringify(callInput[key]) === JSON.stringify(expectedValue),
  );
}

/** The outcome of one reply: the tool names, then, for a case that lists expected input, every call of that tool. */
export function scoreBrainCase(toolCalls: ToolCall[], brainCase: BrainCase): Exclude<Outcome, "error"> {
  const nameOutcome = scoreToolCalls(toolCalls.map((toolCall) => toolCall.name), acceptedAnswersOf(brainCase));
  if (nameOutcome !== "pass") {
    return nameOutcome;
  }
  const everyInputMatches = Object.entries(brainCase.input ?? {}).every(([toolName, expectedInput]) =>
    toolCalls.filter((toolCall) => toolCall.name === toolName).every((toolCall) => inputMatches(toolCall.input, expectedInput)),
  );
  return everyInputMatches ? "pass" : "wrongInput";
}

// ---------- Summary ----------

export type BrainSample = {
  caseId: string;
  context: string;
  runIndex: number;
  httpStatus: number;
  totalMs: number;
  outcome: Outcome;
  toolCalls: ToolCall[];
  /** The text the router wrote next to, or instead of, its tool calls. */
  spokenText: string;
  usageLines: UsageLine[];
  /** Null when the model has no price or the Worker logged no usage line. */
  costUSD: number | null;
};

export type ScoreSummary = {
  runs: number;
  passed: number;
  passRate: number;
  wrongTool: number;
  wrongInput: number;
  missedTool: number;
  spuriousTool: number;
  errors: number;
  p50Ms: number;
  p95Ms: number;
  /** Null when any sample's cost is unknown, so an unpriced call never reads as free. */
  totalCostUSD: number | null;
  meanCostUSD: number | null;
};

/** The cost of one request's usage lines. Null with no line or an unpriced one, so a call that cost money never reads as free. */
export function costOfUsageLines(usageLines: UsageLine[]): number | null {
  const usageLineCosts = usageLines.map(costOfUsageLine);
  return usageLines.length === 0 || usageLineCosts.includes(null) ? null : usageLineCosts.reduce((total: number, cost) => total + (cost ?? 0), 0);
}

export function percentile(sortedValues: number[], fraction: number): number {
  if (sortedValues.length === 0) {
    return NaN;
  }
  const rank = Math.min(sortedValues.length - 1, Math.max(0, Math.ceil(fraction * sortedValues.length) - 1));
  return sortedValues[rank];
}

export function summarizeSamples(samples: BrainSample[]): ScoreSummary {
  const sortedLatencies = samples.map((sample) => sample.totalMs).sort((smaller, larger) => smaller - larger);
  const count = (outcome: Outcome) => samples.filter((sample) => sample.outcome === outcome).length;
  const costIsKnown = samples.length > 0 && samples.every((sample) => sample.costUSD !== null);
  const totalCostUSD = costIsKnown ? samples.reduce((runningCost, sample) => runningCost + (sample.costUSD ?? 0), 0) : null;
  return {
    runs: samples.length,
    passed: count("pass"),
    passRate: samples.length === 0 ? NaN : Number((count("pass") / samples.length).toFixed(4)),
    wrongTool: count("wrongTool"),
    wrongInput: count("wrongInput"),
    missedTool: count("missedTool"),
    spuriousTool: count("spuriousTool"),
    errors: count("error"),
    p50Ms: Math.round(percentile(sortedLatencies, 0.5)),
    p95Ms: Math.round(percentile(sortedLatencies, 0.95)),
    totalCostUSD: totalCostUSD === null ? null : Number(totalCostUSD.toFixed(5)),
    meanCostUSD: totalCostUSD === null ? null : Number((totalCostUSD / samples.length).toFixed(6)),
  };
}

/** Per context in the order the fixture lists them, plus overall. */
export function summarizeByContext(samples: BrainSample[], contextNames: string[]) {
  return {
    overall: summarizeSamples(samples),
    byContext: Object.fromEntries(
      contextNames.map((contextName) => [contextName, summarizeSamples(samples.filter((sample) => sample.context === contextName))]),
    ),
  };
}

// ---------- Tool descriptions in the app source ----------

/** The description of each app tool in VoiceCommandTools.swift's `toolDescription`, by the tool's name. */
export function appToolDescriptionsIn(swiftSource: string): Record<string, string> {
  const enumSource = swiftSource.slice(swiftSource.indexOf("enum AppVoiceTool"));
  const toolNameOfCase = Object.fromEntries(
    [...enumSource.slice(0, enumSource.indexOf("struct Context")).matchAll(/case (\w+) = "([a-z_]+)"/g)].map((caseMatch) => [caseMatch[1], caseMatch[2]]),
  );
  const descriptionStart = enumSource.indexOf("private var toolDescription");
  const descriptionSource = enumSource.slice(descriptionStart, enumSource.indexOf("private var inputSchema", descriptionStart));
  const descriptions: Record<string, string> = {};
  for (const descriptionMatch of descriptionSource.matchAll(/case \.(\w+):\s*\n\s*return "((?:[^"\\]|\\.)*)"/g)) {
    const toolName = toolNameOfCase[descriptionMatch[1]];
    if (toolName !== undefined) {
      // Swift and JSON write the escapes in these strings the same way.
      descriptions[toolName] = JSON.parse(`"${descriptionMatch[2]}"`);
    }
  }
  return descriptions;
}

/** The description of each page tool in scene-tools.js. A tool whose description is a getter, like set_control, is not found. */
export function pageToolDescriptionsIn(sceneToolsSource: string): Record<string, string> {
  const descriptions: Record<string, string> = {};
  for (const toolMatch of sceneToolsSource.matchAll(/name: "([a-z_]+)",\s*\n\s*description: "((?:[^"\\]|\\.)*)",/g)) {
    descriptions[toolMatch[1]] = JSON.parse(`"${toolMatch[2]}"`);
  }
  return descriptions;
}

export function descriptionsInAppSource(appCheckout: string): Record<string, string> {
  return {
    ...pageToolDescriptionsIn(readFileSync(join(appCheckout, "leanring-buddy/LiveSceneAssets/scene-tools.js"), "utf8")),
    ...appToolDescriptionsIn(readFileSync(join(appCheckout, "leanring-buddy/VoiceCommandTools.swift"), "utf8")),
  };
}

/** The tools whose catalog description differs from the app source. A tool the source does not define is not compared. */
export function toolsWithStaleDescriptions(toolCatalog: ToolCatalog, sourceDescriptions: Record<string, string>): string[] {
  return toolCatalog.tools.flatMap((tool) =>
    sourceDescriptions[tool.name] !== undefined && sourceDescriptions[tool.name] !== tool.description ? [tool.name] : [],
  );
}

// ---------- Worker runs ----------

function workerLogPath(workerCheckout: string, port: number): string {
  const logPathRecord = join(workerCheckout, ".verify-clicky", `worker-${port}.logpath`);
  if (!existsSync(logPathRecord)) {
    throw new Error(`No Worker started by verify-clicky in ${workerCheckout} on port ${port}. Run its verify-clicky.sh worker-up ${port}`);
  }
  return readFileSync(logPathRecord, "utf8").trim();
}

async function runOneSample(brainCase: BrainCase, runIndex: number, requestBody: unknown, port: number, logPath: string): Promise<BrainSample> {
  const logOffsetBeforeRequest = statSync(logPath).size;
  const requestStartMs = performance.now();
  const emptySample = { caseId: brainCase.id, context: brainCase.context, runIndex, toolCalls: [], spokenText: "", usageLines: [], costUSD: null };
  let response: Response;
  try {
    response = await fetch(`http://127.0.0.1:${port}/voice-command`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(requestBody),
    });
  } catch (fetchError) {
    const reason = fetchError instanceof Error && fetchError.cause instanceof Error ? fetchError.cause.message : String(fetchError);
    return { ...emptySample, httpStatus: 0, totalMs: performance.now() - requestStartMs, outcome: "error", spokenText: `no reply: ${reason}` };
  }
  const replyText = await response.text();
  const totalMs = performance.now() - requestStartMs;
  if (!response.ok) {
    return { ...emptySample, httpStatus: response.status, totalMs, outcome: "error", spokenText: replyText.slice(0, 200) };
  }

  // The Worker writes its usage line just before it answers, so give wrangler's log a moment to flush.
  await new Promise((resolve) => setTimeout(resolve, 400));
  const usageLines = usageLinesOfRouteInLog(readFileSync(logPath).subarray(logOffsetBeforeRequest).toString("utf8"), "/voice-command");
  const costUSD = costOfUsageLines(usageLines);

  const { toolCalls, spokenText } = toolCallsIn(replyText);
  const outcome = scoreBrainCase(toolCalls, brainCase);
  return { ...emptySample, httpStatus: response.status, totalMs, outcome, toolCalls, spokenText, usageLines, costUSD };
}

function commandLineOption(optionName: string): string | undefined {
  const optionIndex = process.argv.indexOf(`--${optionName}`);
  return optionIndex === -1 ? undefined : process.argv[optionIndex + 1];
}

function writeResultFile(label: string, measuredCheckout: string, result: Record<string, unknown>): string {
  const commitSHA = execFileSync("git", ["-C", measuredCheckout, "rev-parse", "--short=12", "HEAD"], { encoding: "utf8" }).trim();
  const workingTreeIsDirty =
    execFileSync("git", ["-C", measuredCheckout, "status", "--porcelain", "--", "worker", "leanring-buddy", "bench"], { encoding: "utf8" }).trim() !== "";
  const resultsDirectory = join(benchDirectory, "results");
  mkdirSync(resultsDirectory, { recursive: true });
  const resultPath = join(resultsDirectory, `${label}-brain-evals-${commitSHA}.json`);
  const resultWithProvenance = { label, benchKind: "brain-evals", commitSHA, workingTreeIsDirty, recordedAt: new Date().toISOString(), ...result };
  writeFileSync(resultPath, `${JSON.stringify(resultWithProvenance, null, 2)}\n`);
  return resultPath;
}

function loadFixtures(): { evalFile: BrainEvalFile; toolCatalog: ToolCatalog } {
  const evalFile: BrainEvalFile = JSON.parse(readFileSync(casesPath, "utf8"));
  const toolCatalog: ToolCatalog = JSON.parse(readFileSync(toolCatalogPath, "utf8"));
  validateBrainEvals(evalFile, toolCatalog);
  return { evalFile, toolCatalog };
}

function describeCalls(toolCalls: ToolCall[]): string {
  // The confirmation and the goal are the router's own words, which no case checks, so they stay out of the line.
  const inputText = (toolCall: ToolCall) => {
    const checkableInput = Object.fromEntries(Object.entries(toolCall.input).filter(([key]) => key !== "confirmation" && key !== "goal"));
    return Object.keys(checkableInput).length === 0 ? "" : ` ${JSON.stringify(checkableInput)}`;
  };
  return toolCalls.length === 0 ? "no tool" : toolCalls.map((toolCall) => `${toolCall.name}${inputText(toolCall)}`).join(" + ");
}

const acceptedText = (brainCase: BrainCase) => {
  const inputText = brainCase.input === undefined ? "" : ` with input ${JSON.stringify(brainCase.input)}`;
  return `${acceptedAnswersOf(brainCase).map((answer) => (answer.length === 0 ? "no tool" : answer.join(" + "))).join(" | ")}${inputText}`;
};

async function runBrainEvals() {
  const label = commandLineOption("label");
  if (label === undefined) {
    console.error("Usage: node bench/brainEvals.ts run --label <name> [--runs N] [--only caseId,...] [--port 8789] [--checkout <path>]");
    process.exit(1);
  }
  const runCount = Number(commandLineOption("runs") ?? 1);
  const port = Number(commandLineOption("port") ?? 8789);
  const workerCheckout = commandLineOption("checkout") ?? checkoutRoot;
  const { evalFile, toolCatalog } = loadFixtures();

  const onlyCaseIds = commandLineOption("only")?.split(",");
  const unknownCaseIds = (onlyCaseIds ?? []).filter((caseId) => !evalFile.cases.some((brainCase) => brainCase.id === caseId));
  if (unknownCaseIds.length > 0) {
    console.error(`No case named ${unknownCaseIds.join(", ")}. The ids are in bench/fixtures/brain-evals.json.`);
    process.exit(1);
  }
  const selectedCases = evalFile.cases.filter((brainCase) => onlyCaseIds === undefined || onlyCaseIds.includes(brainCase.id));
  const logPath = workerLogPath(workerCheckout, port);

  const samples: BrainSample[] = [];
  for (const brainCase of selectedCases) {
    const requestBody = requestBodyFor(brainCase, evalFile, toolCatalog);
    for (let runIndex = 0; runIndex < runCount; runIndex += 1) {
      const sample = await runOneSample(brainCase, runIndex, requestBody, port, logPath);
      samples.push(sample);
      console.log(
        `${brainCase.id} #${runIndex + 1}: ${Math.round(sample.totalMs)} ms, ${sample.costUSD === null ? "cost unknown" : `$${sample.costUSD.toFixed(5)}`}, ` +
          `${sample.outcome === "pass" ? "PASS" : "FAIL"} ${sample.outcome} (${describeCalls(sample.toolCalls)}; accepts ${acceptedText(brainCase)})`,
      );
    }
  }

  const summary = summarizeByContext(samples, Object.keys(evalFile.contexts));
  const summaryRow = (name: string, scoreSummary: ScoreSummary) => ({
    context: name,
    pass: `${scoreSummary.passed}/${scoreSummary.runs}`,
    rate: `${Math.round(scoreSummary.passRate * 100)}%`,
    wrong: scoreSummary.wrongTool,
    wrongInput: scoreSummary.wrongInput,
    missed: scoreSummary.missedTool,
    spurious: scoreSummary.spuriousTool,
    errors: scoreSummary.errors,
    p50: scoreSummary.p50Ms,
    p95: scoreSummary.p95Ms,
    usd: scoreSummary.totalCostUSD,
  });
  console.table([
    ...Object.entries(summary.byContext).filter(([, scoreSummary]) => scoreSummary.runs > 0).map(([name, scoreSummary]) => summaryRow(name, scoreSummary)),
    summaryRow("overall", summary.overall),
  ]);
  const failedCases = selectedCases.filter((brainCase) => samples.some((sample) => sample.caseId === brainCase.id && sample.outcome !== "pass"));
  for (const brainCase of failedCases) {
    const failedSamples = samples.filter((sample) => sample.caseId === brainCase.id && sample.outcome !== "pass");
    console.log(`FAIL ${brainCase.id} (${failedSamples.length}/${runCount}): "${brainCase.say}" accepts ${acceptedText(brainCase)}, got ${[...new Set(failedSamples.map((sample) => `${sample.outcome}: ${describeCalls(sample.toolCalls)}`))].join("; ")}`);
  }

  const models = [...new Set(samples.flatMap((sample) => sample.usageLines.map((usageLine) => usageLine.model)))];
  console.log(`saved ${writeResultFile(label, workerCheckout, { runCount, port, models, summary, samples })}`);
}

function syncTools() {
  const toolCatalog: ToolCatalog = JSON.parse(readFileSync(toolCatalogPath, "utf8"));
  const sourceDescriptions = descriptionsInAppSource(checkoutRoot);
  const staleToolNames = toolsWithStaleDescriptions(toolCatalog, sourceDescriptions);
  for (const tool of toolCatalog.tools) {
    if (staleToolNames.includes(tool.name)) {
      tool.description = sourceDescriptions[tool.name];
    }
    if (tool.handWritten === true && sourceDescriptions[tool.name] !== undefined) {
      console.log(`${tool.name} is now in the app source. Remove its handWritten flag.`);
    }
  }
  const missingToolNames = Object.keys(sourceDescriptions).filter((toolName) => !toolCatalog.tools.some((tool) => tool.name === toolName));
  if (missingToolNames.length > 0) {
    console.log(`The app source defines tools the catalog lacks: ${missingToolNames.join(", ")}. Add each with its input schema.`);
  }
  writeFileSync(toolCatalogPath, `${JSON.stringify(toolCatalog, null, 2)}\n`);
  console.log(staleToolNames.length === 0 ? "Every description already matches the app source." : `Updated ${staleToolNames.join(", ")}.`);
}

// The functions above are imported by brainEvals.test.ts, which must not start a run.
if (import.meta.main) {
  const command = process.argv[2];
  if (command === "run") {
    await runBrainEvals();
  } else if (command === "sync-tools") {
    syncTools();
  } else {
    console.error("Usage: node bench/brainEvals.ts run --label <name> [--runs N] [--only caseId,...] [--port 8789]\n       node bench/brainEvals.ts sync-tools");
    process.exit(1);
  }
}
