// Brain evals. Measure whether the Haiku voice command router behind POST /voice-command picks the right tool
// for what a learner says, so a model or prompt change cannot quietly change what Clicky does.
//
//   .claude/skills/verify-clicky/verify-clicky.sh worker-up 8797 -- --inspector-port 9307
//   node bench/brainEvals.ts run --label baseline [--runs 1] [--only caseId,...] [--port 8797] [--checkout <path>]
//                                [--backend worker|harness|both] [--harness <clicky-agent-harness>]
//   node bench/brainEvals.ts session-run --label <name> [--runs 3] [--port 8797] [--harness <clicky-agent-harness>]
//   node bench/brainEvals.ts sync-tools
//
// The cases and the screen each one runs in are in fixtures/brain-evals.json. The tools the router is offered are in
// fixtures/brain-evals-tools.json, one descriptor per tool, as the app sends them. Results go to
// bench/results/<label>-brain-evals-<sha>.json. See "Brain evals" in bench/README.md.
//
// Two backends answer the same cases. `worker` posts the request to POST /voice-command, as the app's old path does.
// `harness` sends each case as a `voice_command` to the built Go harness (harness/brain.go), which talks to the same
// Worker's /v1/messages, and answers each `tool_call` with the outcome the app would give that tool. `both` runs the two
// case by case, so the latency comparison shares one network and one Worker. Only the first turn's tool calls are scored,
// since that is what the Worker backend returns. A harness command that takes a second turn, such as the one after
// find_moment's lookup, reports that turn's cost beside the first turn's.
//
// A case marked `scoreWholeCommand` is a planning case: its steps depend on each other, so it is scored on the ordered
// calls of every turn, with a seek's input taken from the timestamp the case scripts, and it reports the cost of all turns.
// It needs the harness's second and third turns, so only the harness backend runs it, and the parity gate leaves it out.
//
// The harness keeps a session across commands, so the harness backend sends `reset_session` before every case, and a case
// that needs earlier commands (`earlierCommands`, and `interruptedBefore` for a command the learner cut short) puts them in
// the session with the bench-only `seed_session`. The harness takes both only because the driver starts it with
// CLICKY_BENCH=1. The cases in fixtures/brain-sessions.json need that history, so only the harness backend runs them, and
// they are scored apart from the parity gate's cases. `session-run` measures a 10 command session against the same ten
// commands with no memory.
//
// The harness decides voice approvals itself and handles `answer_approval` without sending it to the app, so the harness
// backend scores the cases of a context with a waiting request (`approvalWaiting`) from what the harness's approval gate
// settled. It seeds a waiting request with the bench-only `seed_approval_request`, names it in `approvalIDSeenAtPress`, and
// reads the answer from the `approval_settled` line or the `Brain: approval` log line. An unrelated command passes only
// with its own tool call and no settlement. The Worker backend still sends `approvalWaiting` in the scene state and scores
// the tool's input, as the app's old path does.
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
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { readJSONLines, spawnHarness, type HarnessCommand } from "./harnessProcess.ts";
import { parseDevVars } from "./judgeModels.ts";
import { costOfUsageLine, isRecord, usageLinesOfRouteInLog, type UsageLine } from "./usage.ts";

const benchDirectory = dirname(fileURLToPath(import.meta.url));
const checkoutRoot = dirname(benchDirectory);
const casesPath = join(benchDirectory, "fixtures", "brain-evals.json");
const sessionCasesPath = join(benchDirectory, "fixtures", "brain-sessions.json");
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

/**
 * An accepted answer of a `scoreWholeCommand` case that carries its own input, for the case where two different sequences
 * need different inputs: its `input` replaces the case's `input` for the same tool.
 */
export type AcceptedSequence = { calls: string[]; input?: Record<string, Record<string, unknown>> };

/**
 * One acceptable set of tool calls: "none" for a plain spoken answer, a tool name, or several names called together. In a
 * `scoreWholeCommand` case a list is an ordered sequence across all turns, and an `AcceptedSequence` adds input of its own.
 */
export type AcceptedAnswer = string | string[] | AcceptedSequence;

/**
 * Words a string input holds or lacks, by tool name and then input key: `{ seek_to_moment: { query: ["swim", "bladder"] } }`.
 * A word counts when it is a whole word of the input, compared in lower case, so "pop" is not found in "popular".
 */
export type InputWords = Record<string, Record<string, string[]>>;

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
  /**
   * Words each call of a tool must hold in a string input, for an input the learner's words fill in, such as the `query` of
   * `seek_to_moment`, where an exact match would fail every correct wording. Together with `inputOmits` it fails a query
   * that is empty or that repeats the whole request, such as "swim bladder and pop it out".
   */
  inputContains?: InputWords;
  /**
   * Words each call of a tool must not hold in a string input: words of another step of the request or of its framing that a
   * good query would not hold, not common words such as "up" or "go". Each listed word must be one lower case word as `wordsOf`
   * splits text, and the validator refuses one that is not, since it could never match.
   */
  inputOmits?: InputWords;
  /**
   * Set on a planning case, whose steps depend on each other. The case passes when the calls of every turn, in the order
   * they were made, equal one accepted sequence and carry the expected `input`, so `accept` lists ordered sequences and
   * not unordered sets. A sequence that may come in several orders is listed once per order. The harness backend runs
   * these cases, since the Worker backend answers one turn, and the parity gate leaves them out. A sequence that calls
   * find_moment needs the case's `toolResults` to script its result.
   */
  scoreWholeCommand?: true;
  /**
   * Tools the harness must never send to the app in this command, on a planning case. The model's own calls are read
   * from the `Brain: turn` line, which names a call the harness skipped, so this reads the `tool_call` lines the app
   * actually received. It pins the rule that a failed call stops the later calls of its reply: a case that scripts
   * `seek_to_moment` as failed and lists `pop_out` here fails when the pop-out still reaches the app.
   */
  mustNotReachTheApp?: string[];
  /**
   * The router's recent tool call lines, as the app writes them, for a command that corrects the last action. Only the
   * Worker backend reads them, since the harness keeps its own session. A case that has them must also list the same
   * actions as `earlierCommands`, which the harness backend seeds, and brainEvals.test.ts checks that they agree.
   */
  recentActions?: string[];
  /** Commands the learner gave earlier, oldest first. The harness backend seeds them into the session before the case. */
  earlierCommands?: EarlierCommand[];
  /** Action lines of a command the learner interrupted, which the next command's message reports. Harness backend only. */
  interruptedBefore?: string[];
  /** Keys of the context's scene state that the earlier commands changed, so the case's own scene_state matches what they did. Earlier commands keep the context's state. */
  sceneStateChanges?: Record<string, unknown>;
  /**
   * What the app answers a tool's call on the harness backend, by tool name, when the default is not enough. A lookup tool
   * with no entry gets an empty `lookedUp` result, every hand-off tool gets `handedOff`, and every other tool gets `changed`.
   * The Worker backend never runs a tool, so it ignores this.
   */
  toolResults?: Record<string, ScriptedToolResult>;
  /** Why the case exists, for the reader of a failure. */
  why: string;
  /**
   * Set on a session case that today's brain model is known to fail some of the time, with the reason. The run still runs
   * and reports it, and the gate leaves it out, so a known weakness of the model does not block the brain's gate.
   */
  knownMiss?: string;
};

/** One tool call of an earlier command, with the answer the app gave it. */
export type EarlierCall = {
  name: string;
  input: Record<string, unknown>;
  /** What the brain asked Clicky to say. Defaults to "done". */
  confirmation?: string;
  /** The app's result text. Defaults to the text a tool that changed the screen returns. */
  resultText?: string;
};

/** A command the learner gave before the case's own, with the calls the brain made for it. */
export type EarlierCommand = { say: string; calls: EarlierCall[] };

export type BrainEvalFile = {
  /** The skills the app lists in start_background_task, as `TaskAgentSkillCatalog` reads them from its Skills folders. */
  skills?: SkillSummary[];
  contexts: Record<string, EvalContext>;
  cases: BrainCase[];
};

/** What the app's tool step returned, by the wire names of harness/protocol.go's voiceToolOutcome. */
export type VoiceToolOutcomeName = "changed" | "lookedUp" | "handedOff" | "failed";
export type ScriptedToolResult = {
  outcome: VoiceToolOutcomeName;
  /** The lookup's result, such as the caption lines find_moment returns. Used with `lookedUp`. */
  result?: unknown;
  /** Why the tool failed. Used with `failed`. */
  error?: string;
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

/** Each accepted answer as a sequence of tool names, with the input of its own when it has any. "none" is the empty sequence. */
export function acceptedSequencesOf(brainCase: BrainCase): AcceptedSequence[] {
  return brainCase.accept.map((answer) =>
    answer === "none" ? { calls: [] } : typeof answer === "string" ? { calls: [answer] } : Array.isArray(answer) ? { calls: answer } : answer,
  );
}

export function acceptedAnswersOf(brainCase: BrainCase): string[][] {
  return acceptedSequencesOf(brainCase).map((sequence) => sequence.calls);
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

/** The scene_state a case's own command runs in: its context's state, with the keys the case changes, such as the yaw after a turn. */
export function sceneStateOf(brainCase: BrainCase, evalFile: BrainEvalFile): Record<string, unknown> {
  return { ...evalFile.contexts[brainCase.context].sceneState, ...brainCase.sceneStateChanges };
}

/** The /voice-command body for one case: the app's message and the context's tools. */
export function requestBodyFor(brainCase: BrainCase, evalFile: BrainEvalFile, toolCatalog: ToolCatalog) {
  const context = evalFile.contexts[brainCase.context];
  const offeredToolNames = new Set(context.tools);
  return {
    messages: [{ role: "user", content: voiceCommandUserMessageText(brainCase.say, sceneStateOf(brainCase, evalFile), brainCase.recentActions ?? []) }],
    tools: toolCatalog.tools
      .filter((tool) => offeredToolNames.has(tool.name))
      .map((tool) => withSkills(tool, evalFile.skills ?? []))
      .map(({ name, description, inputSchema, readOnly }) => ({ name, description, inputSchema, readOnly })),
  };
}

// ---------- The harness's session ----------

/** The tag harness/brain.go puts around the actions of an interrupted command. brainEvals.test.ts pins it against the Go source. */
export const interruptedBeforeTag = "interrupted_before";

/**
 * Untrusted text as one line that cannot close a tag, as `escapedLine` in harness/brain.go: "<" becomes "‹", a backslash is
 * doubled, and every line break character (CR LF, LF, CR, vertical tab, form feed, U+0085, U+2028, U+2029) becomes \n.
 */
export function escapedLine(text: string): string {
  return text.replaceAll("<", "‹").replaceAll("\\", "\\\\").replace(lineBreakPattern, "\\n");
}

const lineBreakPattern = new RegExp(["\\r\\n", "[\\n\\r\\v\\f\\u0085\\u2028\\u2029]"].join("|"), "g");

/**
 * Compact JSON for a tag, as `taggedJSON` in harness/brain.go: it stays valid JSON, so only "<" becomes "‹" and the line
 * break characters JSON allows raw (U+0085, U+2028, U+2029) become their \u escapes.
 */
export function jsonForTag(compactJSON: string): string {
  return compactJSON.replaceAll("<", "‹").replaceAll("\u0085", "\\u0085").replaceAll("\u2028", "\\u2028").replaceAll("\u2029", "\\u2029");
}

/** What a tool that changed the screen returns, which the app writes as `VoiceToolOutcome.toolResultText`. */
const changedToolResultText = compactJSONText({ ok: true, state: null });

/**
 * Mirrors brainUserMessageText in harness/brain.go, the message the harness's brain reads for each command: the scene, the
 * actions an interrupted command had done, and the learner's words, each in its own tag. The harness backend never builds
 * it, since the harness does, but a seeded session holds earlier commands in the same form.
 */
export function harnessUserMessageText(learnerTranscript: string, sceneState: unknown, interruptedActionLines: string[]): string {
  const interruptedText = interruptedActionLines.length === 0 ? "" : `<${interruptedBeforeTag}>${escapedLine(interruptedActionLines.join("; "))}</${interruptedBeforeTag}>\n`;
  return `<scene_state>${jsonForTag(compactJSONText(sceneState))}</scene_state>\n${interruptedText}<learner_words>${escapedLine(learnerTranscript)}</learner_words>`;
}

/** One earlier call in the app's recent action format, which is also what the harness writes into a fold. */
export function earlierActionLine(call: EarlierCall): string {
  return `${call.name} ${compactJSONText(call.input)} -> ok`;
}

export type SeededMessage = { role: "user" | "assistant"; content: Array<Record<string, unknown>> };

/**
 * The Anthropic messages of earlier commands as the harness's session would hold them: for each command, the user message
 * with the scene and the words, the assistant's tool calls, and the user message with the results. The scene state is the
 * case's own, since the fixtures describe one screen.
 */
export function seedMessagesFor(earlierCommands: EarlierCommand[], sceneState: unknown): SeededMessage[] {
  return earlierCommands.flatMap((earlierCommand, commandIndex): SeededMessage[] => {
    const callIds = earlierCommand.calls.map((_, callIndex) => `toolu_seed_${commandIndex + 1}_${callIndex + 1}`);
    return [
      { role: "user", content: [{ type: "text", text: harnessUserMessageText(earlierCommand.say, sceneState, []) }] },
      {
        role: "assistant",
        content: earlierCommand.calls.map((call, callIndex) => ({
          type: "tool_use",
          id: callIds[callIndex],
          name: call.name,
          input: { ...call.input, confirmation: call.confirmation ?? "done" },
        })),
      },
      {
        role: "user",
        content: earlierCommand.calls.map((call, callIndex) => ({
          type: "tool_result",
          tool_use_id: callIds[callIndex],
          content: [{ type: "text", text: call.resultText ?? changedToolResultText }],
          is_error: false,
        })),
      },
    ];
  });
}

/**
 * The lines the harness backend sends before a case's `voice_command`: a reset, so cases stay independent, a seed when
 * the case needs earlier commands or an interrupted one, and, for a case in a context with a waiting request, a
 * `seed_approval_request` named by the command's ID, so the voice answer has a request in the harness's gate to settle.
 */
export function sessionLinesFor(brainCase: BrainCase, evalFile: BrainEvalFile, commandID?: string): Array<Record<string, unknown>> {
  const lines: Array<Record<string, unknown>> = [{ type: "reset_session" }];
  const waitingCapability = waitingApprovalCapabilityOf(brainCase, evalFile);
  if (waitingCapability !== undefined && commandID !== undefined) {
    // The request a voice answer can settle, in the harness's approval gate with no task behind it.
    lines.push({ type: "seed_approval_request", approvalID: approvalIDFor(commandID), capability: waitingCapability });
  }
  if (brainCase.earlierCommands !== undefined || brainCase.interruptedBefore !== undefined) {
    lines.push({
      type: "seed_session",
      messages: seedMessagesFor(brainCase.earlierCommands ?? [], evalFile.contexts[brainCase.context].sceneState),
      interruptedBefore: brainCase.interruptedBefore ?? [],
    });
  }
  return lines;
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
    for (const [wordsFieldName, inputWords] of [["inputContains", brainCase.inputContains], ["inputOmits", brainCase.inputOmits]] as const) {
      for (const [toolName, wordsByKey] of Object.entries(inputWords ?? {})) {
        if (!acceptedAnswersOf(brainCase).flat().includes(toolName)) {
          throw new Error(`Case ${brainCase.id} checks the words of ${toolName} in ${wordsFieldName}, which no accepted answer calls.`);
        }
        for (const [key, words] of Object.entries(wordsByKey)) {
          if (words.length === 0) {
            throw new Error(`Case ${brainCase.id} lists no words for ${toolName}.${key} in ${wordsFieldName}.`);
          }
          // The scorer compares each listed word with the words `wordsOf` splits the input into, so a listed word that
          // `wordsOf` would split ("pop it out", "x-ray", "he's") or change ("Pop") could never match. A word that is
          // one `wordsOf` word is its own first word, and any other text is not.
          const unmatchableWords = words.filter((word) => wordsOf(word)[0] !== word);
          if (unmatchableWords.length > 0) {
            throw new Error(
              `Case ${brainCase.id} lists words for ${toolName}.${key} in ${wordsFieldName} that are not one lower case whole word each: ${JSON.stringify(unmatchableWords)}.`,
            );
          }
        }
      }
    }
    const holdsSequenceWithInput = brainCase.accept.some((answer) => typeof answer === "object" && !Array.isArray(answer));
    if (holdsSequenceWithInput && brainCase.scoreWholeCommand !== true) {
      throw new Error(`Case ${brainCase.id} is not scored on the whole command, so it cannot hold an accepted sequence with input of its own.`);
    }
    for (const sequence of acceptedSequencesOf(brainCase)) {
      for (const toolName of Object.keys(sequence.input ?? {})) {
        if (!sequence.calls.includes(toolName)) {
          throw new Error(`Case ${brainCase.id} has an accepted sequence that checks the input of ${toolName}, which that sequence does not call.`);
        }
      }
    }
    if (brainCase.scoreWholeCommand === true) {
      if (acceptedAnswersOf(brainCase).some((calls) => calls.length === 0)) {
        throw new Error(`Case ${brainCase.id} is scored on the whole command, so every accepted answer needs at least one call.`);
      }
      if (acceptedAnswersOf(brainCase).flat().includes("find_moment") && brainCase.toolResults?.find_moment?.result === undefined) {
        throw new Error(`Case ${brainCase.id} accepts find_moment, so it must script the lookup's result, or the router has nothing to act on.`);
      }
    }
    if (brainCase.mustNotReachTheApp !== undefined && brainCase.scoreWholeCommand !== true) {
      throw new Error(`Case ${brainCase.id} lists mustNotReachTheApp, which only a case scored on the whole command checks.`);
    }
    for (const toolName of brainCase.mustNotReachTheApp ?? []) {
      if (!context.tools.includes(toolName)) {
        throw new Error(`Case ${brainCase.id} lists ${toolName} in mustNotReachTheApp, which context ${brainCase.context} does not offer.`);
      }
    }
    for (const toolName of Object.keys(brainCase.toolResults ?? {})) {
      if (!context.tools.includes(toolName)) {
        throw new Error(`Case ${brainCase.id} scripts the result of ${toolName}, which context ${brainCase.context} does not offer.`);
      }
    }
    if (brainCase.recentActions !== undefined && brainCase.earlierCommands === undefined) {
      throw new Error(`Case ${brainCase.id} has recentActions, which only the Worker backend reads, and no earlierCommands for the harness backend.`);
    }
    for (const earlierCommand of brainCase.earlierCommands ?? []) {
      if (earlierCommand.say.trim() === "" || earlierCommand.calls.length === 0 || earlierCommand.calls.some((call) => call.name === "")) {
        throw new Error(`Case ${brainCase.id} has an earlier command with no words or no named call.`);
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

/**
 * One tool call. `inputIsUnknown` marks a call the harness backend knows only by its name, from the turn's log line: the app
 * never saw it, because a hand-off ended the turn before it or the brain refused it. A refused call fails a case's input check
 * for its tool. A call after a hand-off in the same reply is not checked, since it never ran (`callsOfOneReplyThatRan`).
 */
export type ToolCall = { name: string; input: Record<string, unknown>; inputIsUnknown?: boolean };

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

/**
 * The calls of one reply that ran. A hand-off ends the reply, so a later call in the same reply never runs: the harness
 * answers it `Not run` and never sends it to the app, which is why the harness backend knows it only by name. Its name still
 * counts for the tool set, and its input is not checked on either backend, since a call that never ran changes nothing.
 * Only the one-reply scorer cuts here. A whole command can go on after a hand-off that did not run, such as a `pop_out`
 * skipped after a failed seek, so `scoreWholeCommand` checks every call it has.
 */
function callsOfOneReplyThatRan(toolCalls: ToolCall[]): ToolCall[] {
  const handOffPosition = toolCalls.findIndex((toolCall) => handOffToolNames.has(toolCall.name));
  return handOffPosition === -1 ? toolCalls : toolCalls.slice(0, handOffPosition + 1);
}

/** Whether every given call, of each listed tool, holds that tool's expected input. A call with an unknown input never does. */
function everyCallHoldsExpectedInput(toolCalls: ToolCall[], expectedInputByToolName: Record<string, Record<string, unknown>>): boolean {
  return Object.entries(expectedInputByToolName).every(([toolName, expectedInput]) =>
    toolCalls.filter((toolCall) => toolCall.name === toolName).every((toolCall) => toolCall.inputIsUnknown !== true && inputMatches(toolCall.input, expectedInput)),
  );
}

/** The whole words of a string, in lower case. */
function wordsOf(text: string): string[] {
  return text.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter((word) => word !== "");
}

/**
 * Whether every call of each listed tool holds the case's words: each `inputContains` word is in the string input, and no
 * `inputOmits` word is. A call with an unknown input, or an input that is not a string, holds none.
 */
function everyCallHoldsExpectedWords(toolCalls: ToolCall[], brainCase: BrainCase): boolean {
  const callHoldsWords = (toolCall: ToolCall, inputWords: InputWords | undefined, wordsMustBeThere: boolean): boolean =>
    Object.entries(inputWords?.[toolCall.name] ?? {}).every(([key, words]) => {
      const inputValue = toolCall.input[key];
      if (toolCall.inputIsUnknown === true || typeof inputValue !== "string") {
        return false;
      }
      const wordsInInput = new Set(wordsOf(inputValue));
      return words.every((word) => wordsInInput.has(word) === wordsMustBeThere);
    });
  return toolCalls.every((toolCall) => callHoldsWords(toolCall, brainCase.inputContains, true) && callHoldsWords(toolCall, brainCase.inputOmits, false));
}

/** The outcome of one reply: the tool names, then, for a case that lists expected input or words, every call of that tool. */
export function scoreBrainCase(toolCalls: ToolCall[], brainCase: BrainCase): Exclude<Outcome, "error"> {
  const nameOutcome = scoreToolCalls(toolCalls.map((toolCall) => toolCall.name), acceptedAnswersOf(brainCase));
  if (nameOutcome !== "pass") {
    return nameOutcome;
  }
  // A call after a hand-off in this reply never ran, so neither its input nor its words are checked.
  const callsThatRan = callsOfOneReplyThatRan(toolCalls);
  return everyCallHoldsExpectedInput(callsThatRan, brainCase.input ?? {}) && everyCallHoldsExpectedWords(callsThatRan, brainCase) ? "pass" : "wrongInput";
}

/**
 * The outcome of a case whose command could answer a waiting request, on the harness backend. The harness handles
 * `answer_approval` itself and never sends it to the app, so the call arrives with no known input, and the answer is read
 * from what the harness's gate settled for the seeded request instead (`approval_settled`, or the `Brain: approval` log line):
 * a case that expects the answer passes only when the model called the tool and the gate took the expected answer, and a
 * case that expects no answer passes only with its own tool call and no settlement. The rest of the case's input is checked as usual.
 */
export function scoreApprovalCase(toolCalls: ToolCall[], settlement: ApprovalSettlement | null, brainCase: BrainCase): Exclude<Outcome, "error"> {
  const { answer_approval: expectedAnswer, ...otherExpectedInput } = brainCase.input ?? {};
  const otherOutcome = scoreBrainCase(toolCalls, { ...brainCase, input: otherExpectedInput });
  if (otherOutcome !== "pass") {
    return otherOutcome;
  }
  if (!toolCalls.some((toolCall) => toolCall.name === "answer_approval")) {
    return settlement === null ? "pass" : "wrongInput";
  }
  if (settlement === null || expectedAnswer === undefined) {
    return "wrongInput";
  }
  const expectedScope = expectedAnswer.always === true ? "always" : "once";
  return settlement.approved === expectedAnswer.approved && settlement.scope === expectedScope ? "pass" : "wrongInput";
}

/**
 * The outcome of a planning case: the calls of every turn, in the order they were made, must equal one accepted sequence,
 * and then each call must hold the expected input, the case's `input` with the sequence's own input over it, and the case's
 * `inputContains` words and none of its `inputOmits` words. A wrong order is a `wrongTool`, like a wrong set of tools. A
 * sequence that is right but takes a seek's time from anywhere but the scripted lookup, or has a string input that lacks an
 * `inputContains` word or holds an `inputOmits` word, is a `wrongInput`.
 */
export function scoreWholeCommand(toolCalls: ToolCall[], brainCase: BrainCase): Exclude<Outcome, "error"> {
  const calledToolNames = toolCalls.map((toolCall) => toolCall.name);
  const sequencesInThisOrder = acceptedSequencesOf(brainCase).filter(
    (sequence) => sequence.calls.length === calledToolNames.length && sequence.calls.every((toolName, position) => toolName === calledToolNames[position]),
  );
  if (sequencesInThisOrder.length === 0) {
    return calledToolNames.length === 0 ? "missedTool" : "wrongTool";
  }
  const someSequenceHoldsItsInput = sequencesInThisOrder.some((sequence) => everyCallHoldsExpectedInput(toolCalls, { ...brainCase.input, ...sequence.input }));
  return someSequenceHoldsItsInput && everyCallHoldsExpectedWords(toolCalls, brainCase) ? "pass" : "wrongInput";
}

// ---------- Summary ----------

export type Backend = "worker" | "harness";

export type BrainSample = {
  /** "sessions" for a case of fixtures/brain-sessions.json and "planning" for a `scoreWholeCommand` case, which the parity gate leaves out. */
  suite?: "sessions" | "planning";
  backend: Backend;
  caseId: string;
  context: string;
  runIndex: number;
  /** The Worker's status. Zero for the harness backend, which has no HTTP reply of its own. */
  httpStatus: number;
  /** The first turn's latency: the request to the Worker's reply, or the `voice_command` line to the harness's first `tool_call` line (to `voice_command_finished` when the first turn calls no tool). */
  totalMs: number;
  /** The `voice_command` line to `voice_command_finished`. Null on the Worker backend, which answers one turn and has no command end. */
  fullCommandMs: number | null;
  /** How many model turns the command took. One on the Worker backend, which sends one request. */
  turnCount: number;
  outcome: Outcome;
  toolCalls: ToolCall[];
  /** The text the router wrote next to, or instead of, its tool calls. */
  spokenText: string;
  usageLines: UsageLine[];
  /** The first turn's cost. Null when the model has no price or the Worker logged no usage line. */
  costUSD: number | null;
  /** The cost of every turn of the command. Null on the Worker backend, or when a turn has no price. */
  fullCommandCostUSD: number | null;
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
  /** p50 of `fullCommandMs`. Null when no sample has one. */
  fullCommandP50Ms: number | null;
  /** Mean of `fullCommandCostUSD`. Null when no sample has one, or any is unknown. */
  meanFullCommandCostUSD: number | null;
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
  const sortedFullCommandLatencies = samples.flatMap((sample) => (sample.fullCommandMs === null ? [] : [sample.fullCommandMs])).sort((smaller, larger) => smaller - larger);
  // A harness command that failed before any turn has no cost, and that must not read as free, so it counts as unknown.
  const fullCommandCosts = samples.filter((sample) => sample.backend === "harness").map((sample) => sample.fullCommandCostUSD);
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
    fullCommandP50Ms: sortedFullCommandLatencies.length === 0 ? null : Math.round(percentile(sortedFullCommandLatencies, 0.5)),
    meanFullCommandCostUSD:
      fullCommandCosts.length === 0 || fullCommandCosts.includes(null)
        ? null
        : Number((fullCommandCosts.reduce((total: number, cost) => total + (cost ?? 0), 0) / fullCommandCosts.length).toFixed(6)),
  };
}

/** The session samples the gate counts: every one except those of a case marked `knownMiss`. */
export function gatedSessionSamples(sessionSamples: BrainSample[], sessionCases: BrainCase[]): BrainSample[] {
  const knownMissCaseIDs = new Set(sessionCases.filter((brainCase) => brainCase.knownMiss !== undefined).map((brainCase) => brainCase.id));
  return sessionSamples.filter((sample) => !knownMissCaseIDs.has(sample.caseId));
}

/** The samples of the cases both backends run, and the samples of the session and planning cases, which only the harness backend runs. */
export function splitBySuite(samples: BrainSample[]): { parityCaseSamples: BrainSample[]; sessionSamples: BrainSample[]; planningSamples: BrainSample[] } {
  return {
    parityCaseSamples: samples.filter((sample) => sample.suite === undefined),
    sessionSamples: samples.filter((sample) => sample.suite === "sessions"),
    planningSamples: samples.filter((sample) => sample.suite === "planning"),
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

/** The wire name of each `AppVoiceTool` case in VoiceCommandTools.swift, by the case's Swift name. */
function appToolNamesByCaseIn(swiftSource: string): Record<string, string> {
  const enumSource = swiftSource.slice(swiftSource.indexOf("enum AppVoiceTool"));
  return Object.fromEntries(
    [...enumSource.slice(0, enumSource.indexOf("struct Context")).matchAll(/case (\w+) = "([a-z_]+)"/g)].map((caseMatch) => [caseMatch[1], caseMatch[2]]),
  );
}

/**
 * Which app tools end a command as a hand-off and which are lookups, read from `appVoiceToolStep` in CompanionManager.swift.
 * A tool is a hand-off when its branch's last return is `.handOff` (an earlier return may be a guard's failure), and a lookup
 * when it returns `.lookedUp`. `build_simulation` hands off only while an experiment waits and otherwise ends in an outcome,
 * so it is in neither list, as in `handOffToolNames`.
 */
export function appToolStepKindsIn(managerSource: string, voiceCommandToolsSource: string): { handOffToolNames: string[]; lookupToolNames: string[] } {
  const toolNameOfCase = appToolNamesByCaseIn(voiceCommandToolsSource);
  const stepStart = managerSource.indexOf("private func appVoiceToolStep(");
  const stepSource = managerSource.slice(stepStart, managerSource.indexOf("// MARK:", stepStart));
  // The tool branches are the `case .name:` lines at the switch's own indent, 8 spaces, so a nested switch's cases do not split one.
  const branches = stepSource.split(/^ {8}case \./m).slice(1);
  const handOffToolNames: string[] = [];
  const lookupToolNames: string[] = [];
  for (const branch of branches) {
    const toolName = toolNameOfCase[branch.slice(0, branch.indexOf(":"))];
    if (toolName === undefined) {
      continue;
    }
    // A guard may fail with an outcome before the branch hands off, so the branch's last return says what it does.
    const lastReturn = [...branch.matchAll(/return \.(handOff|outcome)/g)].at(-1)?.[1];
    if (lastReturn === "handOff") {
      handOffToolNames.push(toolName);
    }
    if (branch.includes(".lookedUp")) {
      lookupToolNames.push(toolName);
    }
  }
  return { handOffToolNames, lookupToolNames };
}

/** The description of each app tool in VoiceCommandTools.swift's `toolDescription`, by the tool's name. */
export function appToolDescriptionsIn(swiftSource: string): Record<string, string> {
  const enumSource = swiftSource.slice(swiftSource.indexOf("enum AppVoiceTool"));
  const toolNameOfCase = appToolNamesByCaseIn(swiftSource);
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

// ---------- Harness runs ----------

/**
 * The tools whose step in CompanionManager.appVoiceToolStep is a hand-off, where a slow path takes over the reply, so the
 * app answers `handedOff` and the command ends. build_simulation is one only while an experiment waits to be shown, and no
 * context here has one waiting.
 */
export const handOffToolNames = new Set([
  "answer_with_screen",
  "build_new_scene",
  "pop_out",
  "animate_picture",
  "close_scene",
  "explain_part",
  "end_quiz",
  "show_ready_model",
  "hear_task_answer",
  "design_theme",
  "show_art_in_my_room",
]);
/** The tools whose step is a read-only lookup, which the model reads before it acts again. */
export const lookupToolNames = new Set(["find_moment"]);

export type StandInToolResult = { outcome: VoiceToolOutcomeName; content: string; isError: boolean };

/**
 * What the app answers a call to one tool, so the harness ends the command as it would in the app: a hand-off ends it, a
 * lookup sends the result back for a second turn, and any other tool changed the screen. The text is the one
 * `VoiceToolOutcome.toolResultText` in VoiceCommandTools.swift writes. A case's `toolResults` replaces the default.
 */
export function standInToolResult(toolName: string, brainCase: BrainCase): StandInToolResult {
  const scriptedResult = brainCase.toolResults?.[toolName];
  const outcome: VoiceToolOutcomeName =
    scriptedResult?.outcome ?? (handOffToolNames.has(toolName) ? "handedOff" : lookupToolNames.has(toolName) ? "lookedUp" : "changed");
  const resultBody = {
    changed: { ok: true, state: null },
    lookedUp: { ok: true, result: scriptedResult?.result ?? [] },
    handedOff: { ok: true },
    failed: { ok: false, error: scriptedResult?.error ?? "the tool failed", state: null },
  }[outcome];
  return { outcome, content: compactJSONText(resultBody), isError: outcome === "failed" };
}

/** What the harness reports for one turn, read from the line `brainUsageLine` writes in harness/brain.go. */
export type BrainTurnUsage = {
  turn: number;
  model: string;
  stopReason: string;
  /** The names of every tool the turn called, in order, including calls the app never saw. Names only, never input. */
  calledToolNames: string[];
  inputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  outputTokens: number;
  /** The harness's own time for the turn's request. */
  elapsedMs: number;
};

// Matches harness/brain.go: "Brain: turn %d on %s stopped for %s, tokens in %d, cache read %d, cache write %d, out %d, %d ms, calls %s",
// where the last field is the call names joined with commas, or "none".
const brainTurnLinePattern =
  /^Brain: turn (\d+) on (\S+) stopped for (\S*), tokens in (\d+), cache read (\d+), cache write (\d+), out (\d+), (\d+) ms, calls (\S+)$/;

/** Null for any other log line, so a changed line shows up as a command with no turns, which has no cost, instead of a wrong number. */
export function parseBrainTurnLine(logMessage: string): BrainTurnUsage | null {
  const lineMatch = brainTurnLinePattern.exec(logMessage);
  if (lineMatch === null) {
    return null;
  }
  return {
    turn: Number(lineMatch[1]),
    model: lineMatch[2],
    stopReason: lineMatch[3],
    calledToolNames: lineMatch[9] === "none" ? [] : lineMatch[9].split(","),
    inputTokens: Number(lineMatch[4]),
    cacheReadTokens: Number(lineMatch[5]),
    cacheWriteTokens: Number(lineMatch[6]),
    outputTokens: Number(lineMatch[7]),
    elapsedMs: Number(lineMatch[8]),
  };
}

/** The turns as usage lines, which the bench's price table reads. */
export function usageLinesOfBrainTurns(turns: BrainTurnUsage[]): UsageLine[] {
  return turns.map((turn) => ({
    route: "/v1/messages",
    model: turn.model,
    serviceTier: undefined,
    inputTokens: turn.inputTokens,
    cacheWriteTokens: turn.cacheWriteTokens,
    cacheReadTokens: turn.cacheReadTokens,
    outputTokens: turn.outputTokens,
  }));
}

export type HarnessCommandEnding = { kind: "finished"; spokenLine: string; gaveUp: boolean } | { kind: "failed"; reason: string };

/** Everything one voice command wrote, with the time of each event since the `voice_command` line was sent. */
export type HarnessCommandRecord = {
  toolCalls: Array<ToolCall & { turnIndex: number; toolUseID: string }>;
  turns: BrainTurnUsage[];
  firstToolCallMs: number | null;
  endedMs: number | null;
  ending: HarnessCommandEnding | null;
  logLines: string[];
  /** The request the command could answer, seeded before it, or null when none waited. */
  approvalID: string | null;
  /** What the harness's gate settled for that request, from an `approval_settled` line or, failing that, the `Brain: approval` log line. Null when nothing was settled. */
  approvalSettlement: ApprovalSettlement | null;
};

export type ApprovalSettlement = { approved: boolean; scope: "once" | "always" };

// These match `undoLastChangeTool` and `undoCallIDSuffix` in harness/brainundo.go, which brainEvals.test.ts checks.
const undoLastChangeTool = "undo_last_change";
const undoCallIDSuffix = "-undo";

// Matches harness/voiceapproval.go: "Brain: approval %s given (once)" or "declined (once)", with the scope in parentheses.
const brainApprovalLinePattern = /^Brain: approval (\S+) (given|declined) \((once|always)\)$/;

/**
 * Reads one voice command's lines from the harness and says what to send back. It records each `tool_call` with its
 * `turnIndex`, answers it with `standInToolResult`, and ends on `voice_command_finished` or `task_failed`. It holds no clock
 * and no process, so a recorded line stream can be replayed through it.
 */
export class HarnessCommandRecorder {
  readonly record: HarnessCommandRecord;
  private readonly brainCase: BrainCase;
  private readonly commandID: string;

  /** `approvalID` is the request the command may answer, which `voiceCommandMessageFor` names in `approvalIDSeenAtPress`. */
  constructor(brainCase: BrainCase, commandID: string, approvalID: string | null = null) {
    this.brainCase = brainCase;
    this.commandID = commandID;
    this.record = { toolCalls: [], turns: [], firstToolCallMs: null, endedMs: null, ending: null, logLines: [], approvalID, approvalSettlement: null };
  }

  get hasEnded(): boolean {
    return this.record.ending !== null;
  }

  /** Takes one parsed harness line and the milliseconds since the command was sent. Returns the line to send back, if any. */
  receive(message: Record<string, unknown>, elapsedMs: number): Record<string, unknown> | null {
    if (message.type === "log") {
      const logMessage = String(message.message);
      this.record.logLines.push(logMessage);
      // A log line names no command, so a turn line that arrives after the command ended is not this command's.
      const turn = this.hasEnded ? null : parseBrainTurnLine(logMessage);
      if (turn !== null) {
        this.record.turns.push(turn);
      }
      // The log line is the fallback for a harness whose approval_settled line was not read, and the line wins when both come.
      const approvalLine = brainApprovalLinePattern.exec(logMessage);
      if (approvalLine !== null && approvalLine[1] === this.record.approvalID && this.record.approvalSettlement === null) {
        this.record.approvalSettlement = { approved: approvalLine[2] === "given", scope: approvalLine[3] as "once" | "always" };
      }
      return null;
    }
    if (message.type === "approval_settled" && message.approvalID === this.record.approvalID && typeof message.approved === "boolean") {
      this.record.approvalSettlement = { approved: message.approved, scope: message.scope === "always" ? "always" : "once" };
      return null;
    }
    if (message.taskID !== this.commandID) {
      return null;
    }
    if (message.type === "tool_call") {
      this.record.firstToolCallMs ??= elapsedMs;
      const toolName = String(message.name);
      this.record.toolCalls.push({ name: toolName, input: isRecord(message.input) ? message.input : {}, turnIndex: Number(message.turnIndex), toolUseID: String(message.toolUseID) });
      const standIn = standInToolResult(toolName, this.brainCase);
      return { type: "tool_result", taskID: this.commandID, toolUseID: message.toolUseID, content: standIn.content, isError: standIn.isError, outcome: standIn.outcome };
    }
    if (message.type === "voice_command_finished") {
      this.record.endedMs = elapsedMs;
      this.record.ending = { kind: "finished", spokenLine: String(message.spokenLine ?? ""), gaveUp: message.gaveUp === true };
    } else if (message.type === "task_failed") {
      this.record.endedMs = elapsedMs;
      this.record.ending = { kind: "failed", reason: String(message.reason) };
    }
    return null;
  }
}

/**
 * The first turn's calls as the Worker backend would score them. The turn's log line names every call the model made,
 * in order, but the app hears only the calls the harness sent as `tool_call` lines: it sends none after a hand-off and
 * none to a tool the command was not offered. A name with no `tool_call` line is a call with no known input, which still
 * counts as a wrong or spurious tool. It fails a case that checks that tool's input, unless it follows a hand-off and never ran.
 */
export function firstTurnToolCalls(record: HarnessCommandRecord): ToolCall[] {
  return toolCallsOfTurn(record, 0);
}

/** Every turn's calls, in the order the model made them, each read as `firstTurnToolCalls` reads the first. */
export function wholeCommandToolCalls(record: HarnessCommandRecord): ToolCall[] {
  return record.turns.flatMap((_, turnIndex) => toolCallsOfTurn(record, turnIndex));
}

function toolCallsOfTurn(record: HarnessCommandRecord, turnIndex: number): ToolCall[] {
  const sentCalls = record.toolCalls.filter((toolCall) => toolCall.turnIndex === turnIndex);
  let nextSentCall = 0;
  return (record.turns[turnIndex]?.calledToolNames ?? []).map((calledToolName) => {
    const sentCall = sentCalls[nextSentCall];
    if (sentCall !== undefined && sentCall.name === calledToolName) {
      nextSentCall += 1;
      return { name: sentCall.name, input: sentCall.input };
    }
    // The harness handles undo_last_change itself and sends the app the inverse of the newest change, under the model's call
    // ID plus a suffix. The learner sees that inverse, so it is the call that is scored. An undo with no such line was refused.
    if (calledToolName === undoLastChangeTool && sentCall?.toolUseID.endsWith(undoCallIDSuffix) === true) {
      nextSentCall += 1;
      return { name: sentCall.name, input: sentCall.input };
    }
    return { name: calledToolName, input: {}, inputIsUnknown: true };
  });
}

/**
 * The sample of one harness command. Only the first turn's calls are scored, which is what the Worker backend returns, and
 * a hand-off or a failure after them changes nothing. A `scoreWholeCommand` case is scored on the calls of every turn
 * instead, and its sample's `toolCalls` are all of them. The first turn's latency is the time to its first tool call, or to
 * the end of the command when the model calls none, since the harness writes nothing between a turn's reply and its end.
 * Both kinds of sample keep the full command's time and cost beside the first turn's.
 */
export function sampleFromHarnessRecord(brainCase: BrainCase, runIndex: number, record: HarnessCommandRecord): BrainSample {
  const baseSample = {
    backend: "harness" as const,
    caseId: brainCase.id,
    context: brainCase.context,
    runIndex,
    httpStatus: 0,
    fullCommandMs: record.endedMs,
    turnCount: record.turns.length,
    usageLines: usageLinesOfBrainTurns(record.turns),
    costUSD: costOfUsageLines(usageLinesOfBrainTurns(record.turns.slice(0, 1))),
    fullCommandCostUSD: costOfUsageLines(usageLinesOfBrainTurns(record.turns)),
  };
  if (record.ending === null || record.ending.kind === "failed" || record.turns.length === 0) {
    const reason =
      record.ending === null ? "the command never ended" : record.ending.kind === "failed" ? record.ending.reason : "the harness wrote no Brain: turn line, so the first turn's calls are unknown";
    return { ...baseSample, totalMs: record.endedMs ?? 0, outcome: "error", toolCalls: [], spokenText: reason };
  }
  const scoredCalls = brainCase.scoreWholeCommand === true ? wholeCommandToolCalls(record) : firstTurnToolCalls(record);
  const outcome =
    brainCase.scoreWholeCommand === true
      ? scoreWholeCommandAndTheCallsTheAppReceived(scoredCalls, record, brainCase)
      : record.approvalID !== null
        ? scoreApprovalCase(scoredCalls, record.approvalSettlement, brainCase)
        : scoreBrainCase(scoredCalls, brainCase);
  return {
    ...baseSample,
    totalMs: record.firstToolCallMs ?? record.endedMs ?? 0,
    outcome,
    toolCalls: scoredCalls,
    spokenText: record.ending.spokenLine,
  };
}

/** `scoreWholeCommand`, then a failure when the app received a call the case says must never reach it. */
function scoreWholeCommandAndTheCallsTheAppReceived(scoredCalls: ToolCall[], record: HarnessCommandRecord, brainCase: BrainCase): Exclude<Outcome, "error"> {
  const wholeCommandOutcome = scoreWholeCommand(scoredCalls, brainCase);
  const aForbiddenCallReachedTheApp = record.toolCalls.some((sentCall) => brainCase.mustNotReachTheApp?.includes(sentCall.name) === true);
  return wholeCommandOutcome === "pass" && aForbiddenCallReachedTheApp ? "wrongTool" : wholeCommandOutcome;
}

/**
 * The kind of action a case's waiting request asks for, such as "sends", or undefined when no request waits. The Worker
 * backend reads it from the scene state, as the app's old path sends it. The harness backend takes it out of the scene state
 * and seeds a request with it instead (`seed_approval_request`), since on the harness path the app sends no approvalWaiting
 * and the harness reads the kind of action from its own approval gate.
 */
export function waitingApprovalCapabilityOf(brainCase: BrainCase, evalFile: BrainEvalFile): string | undefined {
  const capabilityWord = sceneStateOf(brainCase, evalFile).approvalWaiting;
  return typeof capabilityWord === "string" ? capabilityWord : undefined;
}

/** The ID of the request a case's command answers, which the bench seeds before the command and names in `approvalIDSeenAtPress`. */
export function approvalIDFor(commandID: string): string {
  return `approval-${commandID}`;
}

/**
 * The `voice_command` line for one case, with the same words and tools the Worker request has. It carries no recent
 * actions, since the harness keeps earlier commands in its session, which `sessionLinesFor` sets up. A case in a context
 * with a waiting request names that request in `approvalIDSeenAtPress`, as the app does when the learner had seen its card
 * at the press, and its scene state has no `approvalWaiting`, which only the Worker backend sends.
 */
export function voiceCommandMessageFor(brainCase: BrainCase, evalFile: BrainEvalFile, toolCatalog: ToolCatalog, commandID: string) {
  const { approvalWaiting: _approvalWaiting, ...sceneStateWithoutApproval } = sceneStateOf(brainCase, evalFile);
  return {
    type: "voice_command",
    taskID: commandID,
    transcript: brainCase.say,
    sceneState: sceneStateWithoutApproval,
    tools: requestBodyFor(brainCase, evalFile, toolCatalog).tools,
    approvalIDSeenAtPress: waitingApprovalCapabilityOf(brainCase, evalFile) === undefined ? null : approvalIDFor(commandID),
  };
}

export type HarnessBrainProcess = {
  /**
   * Runs one command and records how it ended. Never rejects: a harness that dies or stalls is a command that failed.
   * `sessionLines` are written first, such as `sessionLinesFor`'s reset and seed, and the command's clock starts after them.
   */
  runCommand: (
    voiceCommand: ReturnType<typeof voiceCommandMessageFor>,
    brainCase: BrainCase,
    sessionLines?: Array<Record<string, unknown>>,
  ) => Promise<HarnessCommandRecord>;
  stop: () => void;
};

// A command that ends as gave up can run three Haiku turns at their 8 second limit and then the Sonnet turn at its 30
// second limit, which is 54 seconds before any tool wait, so the driver waits past that and records the harness's own ending.
const harnessCommandTimeoutMs = 60_000;
/** How long an abandoned command gets to show its cancel, so the next command never reads the last lines of the one before. */
const cancelAcknowledgementMs = 2000;

/**
 * Starts the built harness once and runs every command on it, as the app does, so the Anthropic connection stays warm and
 * the latency comparison with the Worker is not charged a process start and a TLS handshake per case. The environment is
 * the minimum, as the app gives it (see `spawnHarness`).
 *
 * A command the driver gives up on gets a `cancel_task`, as a push-to-talk press sends one, and the driver waits for the
 * harness to acknowledge it before the next command starts. A turn's log line names no command, so this is what keeps a
 * late turn of the abandoned command from counting as the next command's first turn.
 */
export async function startHarnessBrain(
  harness: HarnessCommand,
  workerPort: number,
  appSecret: string,
  commandTimeoutMs = harnessCommandTimeoutMs,
): Promise<HarnessBrainProcess> {
  // CLICKY_BENCH=1 lets the harness take reset_session and seed_session. The app never passes it.
  const { harnessProcess, stderrTail } = spawnHarness(harness, workerPort, appSecret, { CLICKY_BENCH: "1" });
  let exitReason: string | null = null;
  let activeCommand: { recorder: HarnessCommandRecorder; commandID: string; startedAt: number; finish: () => void } | null = null;
  let markReady = () => {};
  const readyToTakeCommands = new Promise<void>((resolve) => (markReady = resolve));

  harnessProcess.on("error", (error) => {
    exitReason = `the harness did not start: ${error.message}`;
    markReady();
  });
  // "close", not "exit", so the stderr tail is read before the failure is recorded.
  harnessProcess.on("close", (exitCode) => {
    exitReason = `the harness exited with code ${exitCode}. stderr tail: ${stderrTail()}`;
    markReady();
    activeCommand?.finish();
  });
  readJSONLines(harnessProcess.stdout, (message) => {
    if (message.type === "ready") {
      markReady();
      return;
    }
    if (activeCommand === null) {
      return;
    }
    if (activeCommand.recorder.hasEnded) {
      // The driver gave up on this command and sent a cancel. The command ended or was cancelled in the harness, so what it
      // writes next belongs to no command, and the driver waits here for the line that says so.
      const endedByItself = message.taskID === activeCommand.commandID && (message.type === "voice_command_finished" || message.type === "task_failed");
      const logSaysCancelled = message.type === "log" && String(message.message).startsWith("Brain: command cancelled");
      if (endedByItself || logSaysCancelled) {
        activeCommand.finish();
      }
      return;
    }
    const answer = activeCommand.recorder.receive(message, performance.now() - activeCommand.startedAt);
    if (answer !== null) {
      writeLine(answer);
    }
    if (activeCommand.recorder.hasEnded) {
      activeCommand.finish();
    }
  });

  /** Writes one line to the harness. A write to a closed input ends the active command as failed, instead of throwing. */
  function writeLine(message: Record<string, unknown>) {
    harnessProcess.stdin.write(`${JSON.stringify(message)}\n`, (writeError) => {
      if (writeError) {
        activeCommand?.finish();
      }
    });
  }

  await readyToTakeCommands;

  return {
    runCommand: (voiceCommand, brainCase, sessionLines = []) =>
      new Promise((resolve) => {
        const recorder = new HarnessCommandRecorder(brainCase, voiceCommand.taskID, voiceCommand.approvalIDSeenAtPress);
        let timeoutHandle: ReturnType<typeof setTimeout> | undefined;
        let startedAt = performance.now();
        const finish = () => {
          clearTimeout(timeoutHandle);
          activeCommand = null;
          if (!recorder.hasEnded) {
            recorder.record.ending = { kind: "failed", reason: exitReason ?? "the harness's input was closed" };
            recorder.record.endedMs = performance.now() - startedAt;
          }
          resolve(recorder.record);
        };
        const giveUp = () => {
          recorder.record.ending = { kind: "failed", reason: `the driver gave up after ${commandTimeoutMs / 1000} s` };
          recorder.record.endedMs = performance.now() - startedAt;
          writeLine({ type: "cancel_task", taskID: voiceCommand.taskID });
          timeoutHandle = setTimeout(finish, cancelAcknowledgementMs);
        };
        if (exitReason !== null) {
          finish();
          return;
        }
        activeCommand = { recorder, commandID: voiceCommand.taskID, startedAt, finish };
        timeoutHandle = setTimeout(giveUp, commandTimeoutMs);
        for (const sessionLine of sessionLines) {
          writeLine(sessionLine);
        }
        // The clock starts at the command's own line, so a seed's size is never charged to the command.
        startedAt = performance.now();
        activeCommand.startedAt = startedAt;
        writeLine(voiceCommand);
      }),
    stop: () => {
      harnessProcess.stdin.end();
      setTimeout(() => harnessProcess.kill(), 2000).unref();
    },
  };
}

// ---------- The parity gate ----------

export type ParityCheck = { name: string; passed: boolean; detail: string };

/** The most the harness's p50 to its first tool call may exceed the Worker's p50 from the same run. */
export const parityMostExtraP50Ms = 100;
/** The most the harness's first-turn cost per call may be, as a multiple of the Worker's. */
export const parityMostCostMultiple = 1.5;

/**
 * The gate for the harness brain, from the Worker's and the harness's summaries of the same run: every harness run
 * passes, its p50 to the first tool call is within 100 ms of the Worker's, and its first-turn cost per call is within 1.5
 * times the Worker's. The full-command cost is reported beside it and is not checked. When the run also held the session
 * cases of fixtures/brain-sessions.json, every one of those must pass too, except a case marked `knownMiss`.
 */
export function harnessParityGate(
  workerSummary: ScoreSummary,
  harnessSummary: ScoreSummary,
  sessionSummary?: ScoreSummary,
): { passed: boolean; checks: ParityCheck[] } {
  const extraP50Ms = harnessSummary.p50Ms - workerSummary.p50Ms;
  const costMultiple =
    harnessSummary.meanCostUSD === null || workerSummary.meanCostUSD === null || workerSummary.meanCostUSD === 0
      ? null
      : harnessSummary.meanCostUSD / workerSummary.meanCostUSD;
  const checks: ParityCheck[] = [
    {
      name: "every harness run passes",
      passed: harnessSummary.runs > 0 && harnessSummary.passed === harnessSummary.runs,
      detail: `${harnessSummary.passed} of ${harnessSummary.runs}`,
    },
    {
      name: `p50 to the first tool call within ${parityMostExtraP50Ms} ms of the Worker's`,
      passed: extraP50Ms <= parityMostExtraP50Ms,
      detail: `harness ${harnessSummary.p50Ms} ms, Worker ${workerSummary.p50Ms} ms, ${extraP50Ms >= 0 ? "+" : ""}${extraP50Ms} ms`,
    },
    {
      name: `first-turn cost per call within ${parityMostCostMultiple} times the Worker's`,
      passed: costMultiple !== null && costMultiple <= parityMostCostMultiple,
      detail: `harness $${harnessSummary.meanCostUSD}, Worker $${workerSummary.meanCostUSD}, ${costMultiple === null ? "unknown" : `${costMultiple.toFixed(2)} times`}`,
    },
  ];
  if (sessionSummary !== undefined && sessionSummary.runs > 0) {
    checks.push({
      name: "every session case passes",
      passed: sessionSummary.passed === sessionSummary.runs,
      detail: `${sessionSummary.passed} of ${sessionSummary.runs}`,
    });
  }
  return { passed: checks.every((check) => check.passed), checks };
}

/** Nonzero when the gate ran and failed, so a script or CI step that runs `--backend both` stops on a failed gate. Zero with no gate. */
export function exitCodeOfGate(gate: { passed: boolean } | undefined): number {
  return gate === undefined || gate.passed ? 0 : 1;
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
  const emptySample = {
    backend: "worker" as const,
    caseId: brainCase.id,
    context: brainCase.context,
    runIndex,
    fullCommandMs: null,
    turnCount: 1,
    toolCalls: [],
    spokenText: "",
    usageLines: [],
    costUSD: null,
    fullCommandCostUSD: null,
  };
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

/** Runs one case on the started harness: the session lines (a reset, a seeded session, a seeded approval request) and then the command, with an ID that names its own request. */
export function runCaseOnTheHarness(harnessBrain: HarnessBrainProcess, brainCase: BrainCase, evalFile: BrainEvalFile, toolCatalog: ToolCatalog): Promise<HarnessCommandRecord> {
  const commandID = `eval-${randomUUID()}`;
  return harnessBrain.runCommand(voiceCommandMessageFor(brainCase, evalFile, toolCatalog, commandID), brainCase, sessionLinesFor(brainCase, evalFile, commandID));
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

/**
 * fixtures/brain-sessions.json: cases that need the harness's session, and one session of ten commands that `session-run`
 * measures. Both use the contexts of brain-evals.json.
 */
export type SessionFixture = {
  cases: BrainCase[];
  measuredSession: { context: string; commands: Array<{ say: string; accept: AcceptedAnswer[] }> };
};

/** Throws a message naming the first problem in the session fixture, with every case checked as brain-evals.json's are. */
export function validateSessionFixture(sessionFile: SessionFixture, evalFile: BrainEvalFile, toolCatalog: ToolCatalog): void {
  validateBrainEvals({ ...evalFile, cases: [...evalFile.cases, ...sessionFile.cases] }, toolCatalog);
  const measuredContext = evalFile.contexts[sessionFile.measuredSession.context];
  if (measuredContext === undefined || sessionFile.measuredSession.commands.length === 0) {
    throw new Error("The measured session needs a known context and at least one command.");
  }
  for (const command of sessionFile.measuredSession.commands) {
    for (const toolName of acceptedAnswersOf(measuredCommandCase(command, sessionFile.measuredSession.context, 0)).flat()) {
      if (!measuredContext.tools.includes(toolName)) {
        throw new Error(`The measured command "${command.say}" accepts ${toolName}, which context ${sessionFile.measuredSession.context} does not offer.`);
      }
    }
  }
}

/** A measured session's command as a case, so it is scored like any other. */
export function measuredCommandCase(command: SessionFixture["measuredSession"]["commands"][number], context: string, commandIndex: number): BrainCase {
  return { id: `measured-${commandIndex + 1}`, context, say: command.say, accept: command.accept, why: "A command of the measured session." };
}

function loadFixtures(): { evalFile: BrainEvalFile; toolCatalog: ToolCatalog; sessionFile: SessionFixture } {
  const evalFile: BrainEvalFile = JSON.parse(readFileSync(casesPath, "utf8"));
  const toolCatalog: ToolCatalog = JSON.parse(readFileSync(toolCatalogPath, "utf8"));
  const sessionFile: SessionFixture = JSON.parse(readFileSync(sessionCasesPath, "utf8"));
  validateBrainEvals(evalFile, toolCatalog);
  validateSessionFixture(sessionFile, evalFile, toolCatalog);
  return { evalFile, toolCatalog, sessionFile };
}

function describeCalls(toolCalls: ToolCall[], separator = " + "): string {
  // The confirmation and the goal are the router's own words, which no case checks, so they stay out of the line.
  const inputText = (toolCall: ToolCall) => {
    const checkableInput = Object.fromEntries(Object.entries(toolCall.input).filter(([key]) => key !== "confirmation" && key !== "goal"));
    return Object.keys(checkableInput).length === 0 ? "" : ` ${JSON.stringify(checkableInput)}`;
  };
  return toolCalls.length === 0 ? "no tool" : toolCalls.map((toolCall) => `${toolCall.name}${inputText(toolCall)}`).join(separator);
}

const acceptedText = (brainCase: BrainCase) => {
  const inputText = [
    brainCase.input === undefined ? "" : ` with input ${JSON.stringify(brainCase.input)}`,
    brainCase.inputContains === undefined ? "" : ` holding ${JSON.stringify(brainCase.inputContains)}`,
    brainCase.inputOmits === undefined ? "" : ` omitting ${JSON.stringify(brainCase.inputOmits)}`,
  ].join("");
  // A planning case's sequences are ordered, so they read as a chain, and a sequence's own input shows beside it.
  const separator = brainCase.scoreWholeCommand === true ? " > " : " + ";
  const sequenceTexts = acceptedSequencesOf(brainCase).map((sequence) => {
    const calledText = sequence.calls.length === 0 ? "no tool" : sequence.calls.join(separator);
    return sequence.input === undefined ? calledText : `${calledText} with input ${JSON.stringify(sequence.input)}`;
  });
  return `${sequenceTexts.join(" | ")}${inputText}`;
};

const backendNames: Backend[] = ["worker", "harness"];

/** Builds the harness from this checkout into bench/.harness, so a run never measures a stale binary. */
function buildHarness(): string {
  const harnessPath = join(benchDirectory, ".harness", "clicky-agent-harness");
  mkdirSync(dirname(harnessPath), { recursive: true });
  execFileSync("go", ["build", "-o", harnessPath, "."], { cwd: join(checkoutRoot, "harness"), stdio: "inherit" });
  return harnessPath;
}

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

/** A planning case's row: the outcome counts, and the time and cost of the whole command, since the first turn alone says little. */
const planningRow = (name: string, scoreSummary: ScoreSummary) => ({
  case: name,
  pass: `${scoreSummary.passed}/${scoreSummary.runs}`,
  rate: `${Math.round(scoreSummary.passRate * 100)}%`,
  wrong: scoreSummary.wrongTool,
  wrongInput: scoreSummary.wrongInput,
  missed: scoreSummary.missedTool,
  errors: scoreSummary.errors,
  fullP50: scoreSummary.fullCommandP50Ms,
  meanFullUsd: scoreSummary.meanFullCommandCostUSD,
});

async function runBrainEvals() {
  const label = commandLineOption("label");
  if (label === undefined) {
    console.error(
      "Usage: node bench/brainEvals.ts run --label <name> [--runs N] [--only caseId,...] [--port 8789] [--checkout <path>] [--backend worker|harness|both] [--harness <path>]",
    );
    process.exit(1);
  }
  const runCount = Number(commandLineOption("runs") ?? 1);
  const port = Number(commandLineOption("port") ?? 8789);
  const workerCheckout = commandLineOption("checkout") ?? checkoutRoot;
  const backendOption = commandLineOption("backend") ?? "worker";
  if (backendOption !== "worker" && backendOption !== "harness" && backendOption !== "both") {
    console.error(`--backend must be worker, harness, or both, not ${backendOption}.`);
    process.exit(1);
  }
  const backends: Backend[] = backendOption === "both" ? backendNames : [backendOption];
  const { evalFile, toolCatalog, sessionFile } = loadFixtures();

  const onlyCaseIds = commandLineOption("only")?.split(",");
  const unknownCaseIds = (onlyCaseIds ?? []).filter((caseId) => ![...evalFile.cases, ...sessionFile.cases].some((brainCase) => brainCase.id === caseId));
  if (unknownCaseIds.length > 0) {
    console.error(`No case named ${unknownCaseIds.join(", ")}. The ids are in bench/fixtures/brain-evals.json and brain-sessions.json.`);
    process.exit(1);
  }
  const caseIsSelected = (brainCase: BrainCase) => onlyCaseIds === undefined || onlyCaseIds.includes(brainCase.id);
  // The Worker backend answers one turn, so the planning cases, which need every turn, run only on the harness backend.
  const selectedCases = evalFile.cases.filter((brainCase) => brainCase.scoreWholeCommand !== true && caseIsSelected(brainCase));
  const selectedPlanningCases = backends.includes("harness") ? evalFile.cases.filter((brainCase) => brainCase.scoreWholeCommand === true && caseIsSelected(brainCase)) : [];
  if (!backends.includes("harness") && evalFile.cases.some((brainCase) => brainCase.scoreWholeCommand === true && caseIsSelected(brainCase))) {
    console.log("The planning cases run only on the harness backend, so this run leaves them out. Add --backend harness or both.");
  }
  // The session cases need the harness's memory, so the Worker backend never runs them.
  const selectedSessionCases = backends.includes("harness") ? sessionFile.cases.filter(caseIsSelected) : [];
  const logPath = workerLogPath(workerCheckout, port);

  let harnessBrain: HarnessBrainProcess | undefined;
  if (backends.includes("harness")) {
    const appSecret = parseDevVars(readFileSync(join(workerCheckout, "worker/.dev.vars"), "utf8")).CLICKY_APP_SECRET;
    if (appSecret === undefined || appSecret === "") {
      console.error("worker/.dev.vars has no CLICKY_APP_SECRET, so the Worker would answer 401 to the harness.");
      process.exit(1);
    }
    harnessBrain = await startHarnessBrain({ command: commandLineOption("harness") ?? buildHarness(), args: [] }, port, appSecret);
  }

  const samples: BrainSample[] = [];
  try {
    for (const [caseIndex, brainCase] of selectedCases.entries()) {
      const requestBody = requestBodyFor(brainCase, evalFile, toolCatalog);
      for (let runIndex = 0; runIndex < runCount; runIndex += 1) {
        // Backends alternate case by case, and which one goes first flips each time, so neither always follows the other.
        const orderedBackends = (caseIndex + runIndex) % 2 === 0 ? backends : [...backends].reverse();
        for (const backend of orderedBackends) {
          const sample =
            backend === "worker" || harnessBrain === undefined
              ? await runOneSample(brainCase, runIndex, requestBody, port, logPath)
              : sampleFromHarnessRecord(brainCase, runIndex, await runCaseOnTheHarness(harnessBrain, brainCase, evalFile, toolCatalog));
          samples.push(sample);
          logSample(backend, brainCase, runIndex, sample);
        }
      }
    }
    const harnessOnlyCases = [
      ...selectedSessionCases.map((brainCase) => ({ brainCase, suite: "sessions" as const })),
      ...selectedPlanningCases.map((brainCase) => ({ brainCase, suite: "planning" as const })),
    ];
    for (const { brainCase, suite } of harnessBrain === undefined ? [] : harnessOnlyCases) {
      for (let runIndex = 0; runIndex < runCount; runIndex += 1) {
        const record = harnessBrain === undefined ? undefined : await runCaseOnTheHarness(harnessBrain, brainCase, evalFile, toolCatalog);
        if (record === undefined) {
          continue;
        }
        const sample: BrainSample = { ...sampleFromHarnessRecord(brainCase, runIndex, record), suite };
        samples.push(sample);
        logSample("harness", brainCase, runIndex, sample);
      }
    }
  } finally {
    harnessBrain?.stop();
  }

  // The parity gate and the tables below count only the cases both backends run.
  const { parityCaseSamples, sessionSamples, planningSamples } = splitBySuite(samples);
  const summaryByBackend = Object.fromEntries(
    backends.map((backend) => [backend, summarizeByContext(parityCaseSamples.filter((sample) => sample.backend === backend), Object.keys(evalFile.contexts))]),
  );
  const sessionSummary = sessionSamples.length === 0 ? undefined : summarizeSamples(sessionSamples);
  if (sessionSummary !== undefined) {
    console.log("session cases (harness backend only)");
    console.table([summaryRow("sessions", sessionSummary)]);
    for (const brainCase of selectedSessionCases) {
      const failedSamples = sessionSamples.filter((sample) => sample.caseId === brainCase.id && sample.outcome !== "pass");
      if (failedSamples.length > 0) {
        console.log(
          `${brainCase.knownMiss === undefined ? "FAIL" : "KNOWN MISS"} sessions ${brainCase.id} (${failedSamples.length}/${runCount}): "${brainCase.say}" accepts ${acceptedText(brainCase)}, got ${[...new Set(failedSamples.map((sample) => `${sample.outcome}: ${describeCalls(sample.toolCalls)}`))].join("; ")}`,
        );
      }
    }
  }
  const planningSummary = planningSamples.length === 0 ? undefined : summarizeSamples(planningSamples);
  if (planningSummary !== undefined) {
    console.log("planning cases (harness backend only, scored on the whole command)");
    console.table([planningRow("planning", planningSummary), ...selectedPlanningCases.map((brainCase) => planningRow(brainCase.id, summarizeSamples(planningSamples.filter((sample) => sample.caseId === brainCase.id))))]);
    for (const brainCase of selectedPlanningCases) {
      const failedSamples = planningSamples.filter((sample) => sample.caseId === brainCase.id && sample.outcome !== "pass");
      if (failedSamples.length > 0) {
        console.log(
          `FAIL planning ${brainCase.id} (${failedSamples.length}/${runCount}): "${brainCase.say}" accepts ${acceptedText(brainCase)}, got ${[...new Set(failedSamples.map((sample) => `${sample.outcome}: ${describeCalls(sample.toolCalls, " > ")}`))].join("; ")}`,
        );
      }
    }
  }
  for (const backend of backends) {
    const summary = summaryByBackend[backend];
    // A run limited to planning or session cases has no parity cases, and an empty table of NaN says nothing.
    if (summary.overall.runs === 0) {
      continue;
    }
    console.log(`${backend} backend`);
    console.table([
      ...Object.entries(summary.byContext).filter(([, scoreSummary]) => scoreSummary.runs > 0).map(([name, scoreSummary]) => summaryRow(name, scoreSummary)),
      summaryRow("overall", summary.overall),
    ]);
    if (backend === "harness") {
      console.log(
        `harness full command: p50 ${summary.overall.fullCommandP50Ms} ms, mean cost $${summary.overall.meanFullCommandCostUSD} per command, ` +
          `against first turn p50 ${summary.overall.p50Ms} ms and $${summary.overall.meanCostUSD} per command`,
      );
    }
    const failedCases = selectedCases.filter((brainCase) => samples.some((sample) => sample.backend === backend && sample.caseId === brainCase.id && sample.outcome !== "pass"));
    for (const brainCase of failedCases) {
      const failedSamples = samples.filter((sample) => sample.backend === backend && sample.caseId === brainCase.id && sample.outcome !== "pass");
      console.log(
        `FAIL ${backend} ${brainCase.id} (${failedSamples.length}/${runCount}): "${brainCase.say}" accepts ${acceptedText(brainCase)}, got ${[...new Set(failedSamples.map((sample) => `${sample.outcome}: ${describeCalls(sample.toolCalls)}`))].join("; ")}`,
      );
    }
  }

  const gatedSessionSummary = sessionSummary === undefined ? undefined : summarizeSamples(gatedSessionSamples(sessionSamples, selectedSessionCases));
  const gate = backendOption === "both" ? harnessParityGate(summaryByBackend.worker.overall, summaryByBackend.harness.overall, gatedSessionSummary) : undefined;
  for (const check of gate?.checks ?? []) {
    console.log(`${check.passed ? "GATE PASS" : "GATE FAIL"} ${check.name}: ${check.detail}`);
  }

  const models = [...new Set(samples.flatMap((sample) => sample.usageLines.map((usageLine) => usageLine.model)))];
  console.log(`saved ${writeResultFile(label, workerCheckout, { runCount, port, backend: backendOption, models, gate, summaryByBackend, sessionSummary, planningSummary, samples })}`);
  process.exitCode = exitCodeOfGate(gate);
}

function logSample(backend: Backend, brainCase: BrainCase, runIndex: number, sample: BrainSample) {
  console.log(
    `${backend} ${brainCase.id} #${runIndex + 1}: ${Math.round(sample.totalMs)} ms, ${sample.costUSD === null ? "cost unknown" : `$${sample.costUSD.toFixed(5)}`}, ` +
      `${sample.outcome === "pass" ? "PASS" : "FAIL"} ${sample.outcome} (${describeCalls(sample.toolCalls, brainCase.scoreWholeCommand === true ? " > " : " + ")}; accepts ${acceptedText(brainCase)})` +
      (sample.outcome === "error" ? ` ${sample.spokenText}` : ""),
  );
}

// ---------- The 10 command session ----------

/** Cached input tokens as a share of all input tokens (fresh, cache read, and cache write) over every turn of the samples. */
export function cacheReadShare(samples: BrainSample[]): number {
  const lines = samples.flatMap((sample) => sample.usageLines);
  const cacheRead = lines.reduce((total, line) => total + line.cacheReadTokens, 0);
  const allInput = lines.reduce((total, line) => total + line.inputTokens + line.cacheReadTokens + line.cacheWriteTokens, 0);
  return allInput === 0 ? NaN : Number((cacheRead / allInput).toFixed(4));
}

export type SessionMeasure = {
  commands: number;
  passed: number;
  cacheReadShare: number;
  /** p50 of the time to the first tool call. */
  p50Ms: number;
  p95Ms: number;
  meanFirstTurnCostUSD: number | null;
  meanFullCommandCostUSD: number | null;
};

export function measureSession(samples: BrainSample[]): SessionMeasure {
  const summary = summarizeSamples(samples);
  return {
    commands: samples.length,
    passed: summary.passed,
    cacheReadShare: cacheReadShare(samples),
    p50Ms: summary.p50Ms,
    p95Ms: summary.p95Ms,
    meanFirstTurnCostUSD: summary.meanCostUSD,
    meanFullCommandCostUSD: summary.meanFullCommandCostUSD,
  };
}

/**
 * Runs the fixture's measured session twice per run on one harness: as one conversation (reset once, then each command sees
 * the ones before it), and as the same commands with a reset before each, which is how the brain behaved with no memory.
 * The two are then compared on cache read share, p50, and cost.
 */
async function runSessionMeasure() {
  const label = commandLineOption("label");
  if (label === undefined) {
    console.error("Usage: node bench/brainEvals.ts session-run --label <name> [--runs 3] [--port 8797] [--checkout <path>] [--harness <path>]");
    process.exit(1);
  }
  const runCount = Number(commandLineOption("runs") ?? 3);
  const port = Number(commandLineOption("port") ?? 8789);
  const workerCheckout = commandLineOption("checkout") ?? checkoutRoot;
  const { evalFile, toolCatalog, sessionFile } = loadFixtures();
  const appSecret = parseDevVars(readFileSync(join(workerCheckout, "worker/.dev.vars"), "utf8")).CLICKY_APP_SECRET;
  if (appSecret === undefined || appSecret === "") {
    console.error("worker/.dev.vars has no CLICKY_APP_SECRET, so the Worker would answer 401 to the harness.");
    process.exit(1);
  }
  const measuredCases = sessionFile.measuredSession.commands.map((command, commandIndex) => measuredCommandCase(command, sessionFile.measuredSession.context, commandIndex));
  const harnessBrain = await startHarnessBrain({ command: commandLineOption("harness") ?? buildHarness(), args: [] }, port, appSecret);

  const samplesByMode: Record<"session" | "stateless", BrainSample[]> = { session: [], stateless: [] };
  try {
    for (let runIndex = 0; runIndex < runCount; runIndex += 1) {
      // Which mode goes first flips each run, so neither always follows the other.
      for (const mode of runIndex % 2 === 0 ? (["stateless", "session"] as const) : (["session", "stateless"] as const)) {
        for (const [commandIndex, brainCase] of measuredCases.entries()) {
          // Stateless resets before every command. The session resets once, so each command reads the ones before it.
          const sessionLines = mode === "stateless" || commandIndex === 0 ? [{ type: "reset_session" }] : [];
          const record = await harnessBrain.runCommand(voiceCommandMessageFor(brainCase, evalFile, toolCatalog, `eval-${randomUUID()}`), brainCase, sessionLines);
          const sample = sampleFromHarnessRecord(brainCase, runIndex, record);
          samplesByMode[mode].push(sample);
          console.log(`${mode} run ${runIndex + 1} command ${commandIndex + 1} "${brainCase.say}": ${Math.round(sample.totalMs)} ms, ${sample.outcome}, ${describeCalls(sample.toolCalls)}`);
        }
      }
    }
  } finally {
    harnessBrain.stop();
  }

  const measures = { session: measureSession(samplesByMode.session), stateless: measureSession(samplesByMode.stateless) };
  console.table(measures);
  console.log(`saved ${writeResultFile(label, workerCheckout, { runCount, port, measures, samples: [...samplesByMode.session.map((sample) => ({ ...sample, mode: "session" })), ...samplesByMode.stateless.map((sample) => ({ ...sample, mode: "stateless" }))] })}`);
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
  } else if (command === "session-run") {
    await runSessionMeasure();
  } else if (command === "sync-tools") {
    syncTools();
  } else {
    console.error(
      "Usage: node bench/brainEvals.ts run --label <name> [--runs N] [--only caseId,...] [--port 8789] [--backend worker|harness|both]\n       node bench/brainEvals.ts session-run --label <name> [--runs 3] [--port 8789]\n       node bench/brainEvals.ts sync-tools",
    );
    process.exit(1);
  }
}
