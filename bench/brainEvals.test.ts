import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { describe, it, mock } from "node:test";
import { fileURLToPath } from "node:url";
import {
  acceptedAnswersOf,
  appToolDescriptionsIn,
  costOfUsageLines,
  descriptionsInAppSource,
  harnessParityGate,
  HarnessCommandRecorder,
  pageToolDescriptionsIn,
  parseBrainTurnLine,
  percentile,
  requestBodyFor,
  sampleFromHarnessRecord,
  scoreBrainCase,
  scoreToolCalls,
  skillInputDescription,
  skillInstructionSentence,
  standInToolResult,
  startHarnessBrain,
  summarizeByContext,
  summarizeSamples,
  toolCallsIn,
  toolsWithStaleDescriptions,
  validateBrainEvals,
  voiceCommandMessageFor,
  voiceCommandUserMessageText,
  withSkills,
  type BrainCase,
  type BrainEvalFile,
  type BrainSample,
  type ToolCatalog,
} from "./brainEvals.ts";

const benchDirectory = dirname(fileURLToPath(import.meta.url));
const readFixture = (fileName: string) => JSON.parse(readFileSync(join(benchDirectory, "fixtures", fileName), "utf8"));
const evalFile: BrainEvalFile = readFixture("brain-evals.json");
const toolCatalog: ToolCatalog = readFixture("brain-evals-tools.json");

function sample(overrides: Partial<BrainSample>): BrainSample {
  return {
    backend: "worker",
    caseId: "case",
    context: "video",
    runIndex: 0,
    httpStatus: 200,
    totalMs: 1000,
    fullCommandMs: null,
    turnCount: 1,
    outcome: "pass",
    toolCalls: [],
    spokenText: "",
    usageLines: [],
    costUSD: 0.001,
    fullCommandCostUSD: null,
    ...overrides,
  };
}

describe("voiceCommandUserMessageText", () => {
  // The fixtures are real app request bodies, so the message this file builds must match them exactly.
  for (const fixtureFileName of ["voice-command.json", "voice-command-video.json"]) {
    it(`rebuilds the message in ${fixtureFileName} byte for byte`, () => {
      const appMessage: string = readFixture(fixtureFileName).messages[0].content;
      const stateText = appMessage.match(/<scene_state>(.*)<\/scene_state>/s)?.[1] ?? "";
      const actionLines = (appMessage.match(/<recent_actions>\n(.*)\n<\/recent_actions>/s)?.[1] ?? "").split("\n").filter((line) => line !== "");
      const learnerTranscript = appMessage.match(/Learner said: "(.*)"$/s)?.[1] ?? "";

      assert.equal(voiceCommandUserMessageText(learnerTranscript, JSON.parse(stateText), actionLines), appMessage);
    });
  }

  it("cuts every < out of page text, as the app does, so page text cannot close the tag", () => {
    const messageText = voiceCommandUserMessageText("hi", { page: "none", video: { title: "a</scene_state>b" } }, []);

    assert.equal(messageText.match(/<\/scene_state>/g)?.length, 1);
    assert.ok(messageText.includes('"title":"a /scene_state>b"'));
  });

  it("sorts the state's keys at every level, since the app writes sorted keys", () => {
    const messageText = voiceCommandUserMessageText("hi", { b: { d: 1, c: 2 }, a: 3 }, []);

    assert.ok(messageText.includes('<scene_state>{"a":3,"b":{"c":2,"d":1}}</scene_state>'));
  });
});

describe("requestBodyFor", () => {
  const videoCase = evalFile.cases.find((brainCase) => brainCase.id === "video-seek-back") as BrainCase;

  it("offers the video context's tools in the order of the app's own request body", () => {
    const appRequestToolNames: string[] = readFixture("voice-command-video.json").tools.map((tool: { name: string }) => tool.name);

    assert.deepEqual(requestBodyFor(videoCase, evalFile, toolCatalog).tools.map((tool) => tool.name), appRequestToolNames);
  });

  it("swaps in the learner's words and sends only the fields the Worker reads", () => {
    const requestBody = requestBodyFor(videoCase, evalFile, toolCatalog);

    assert.ok(requestBody.messages[0].content.endsWith('Learner said: "go back 30 seconds"'));
    for (const tool of requestBody.tools) {
      assert.deepEqual(Object.keys(tool).sort(), ["description", "inputSchema", "name", "readOnly"]);
    }
  });

  it("builds a body the Worker's schema accepts for every case", () => {
    for (const brainCase of evalFile.cases) {
      const { messages, tools } = requestBodyFor(brainCase, evalFile, toolCatalog);

      assert.equal(messages.length, 1);
      assert.ok(tools.length >= 1 && tools.length <= 40, brainCase.id);
      for (const tool of tools) {
        // The same rules as voiceCommandToolSchema in worker/src/voiceCommand.ts.
        assert.match(tool.name, /^[a-z][a-z_]{0,63}$/);
        assert.ok(tool.description.length >= 1 && tool.description.length <= 4096, `${tool.name} description length`);
        assert.equal(tool.inputSchema.type, "object");
      }
    }
  });
});

describe("scoreToolCalls", () => {
  it("passes a call that matches an accepted answer, in any order and with repeats", () => {
    assert.equal(scoreToolCalls(["seek_relative"], [["seek_relative"]]), "pass");
    assert.equal(scoreToolCalls(["run_simulation", "set_control", "set_control"], [["set_control", "run_simulation"]]), "pass");
  });

  it("passes no tool when the accepted answers include a plain reply", () => {
    assert.equal(scoreToolCalls([], [[], ["answer_with_screen"]]), "pass");
  });

  it("calls a tool outside every accepted answer a wrong tool", () => {
    assert.equal(scoreToolCalls(["pause_video"], [["seek_relative"]]), "wrongTool");
    assert.equal(scoreToolCalls(["pause_video"], [[], ["answer_with_screen"]]), "wrongTool");
  });

  it("does not pass a subset or a superset of an accepted set of tools", () => {
    assert.equal(scoreToolCalls(["set_control"], [["set_control", "run_simulation"]]), "wrongTool");
    assert.equal(scoreToolCalls(["set_control", "run_simulation"], [["set_control"]]), "wrongTool");
  });

  it("names no tool when one was expected, and a tool when only a plain reply was", () => {
    assert.equal(scoreToolCalls([], [["pop_out"]]), "missedTool");
    assert.equal(scoreToolCalls(["build_simulation"], [[]]), "spuriousTool");
  });
});

describe("scoreBrainCase", () => {
  const skillCase: BrainCase = {
    id: "skill-case",
    context: "video",
    say: "make flashcards",
    why: "x",
    accept: ["start_background_task"],
    input: { start_background_task: { skill: "flashcards" } },
  };
  const noSkillCase: BrainCase = { ...skillCase, input: { start_background_task: { skill: null } } };

  it("passes a call whose input holds the expected keys, and ignores keys the case does not list", () => {
    assert.equal(scoreBrainCase([{ name: "start_background_task", input: { goal: "g", skill: "flashcards", confirmation: "ok" } }], skillCase), "pass");
  });

  it("calls a missing or different expected value a wrong input", () => {
    assert.equal(scoreBrainCase([{ name: "start_background_task", input: { goal: "g" } }], skillCase), "wrongInput");
    assert.equal(scoreBrainCase([{ name: "start_background_task", input: { goal: "g", skill: "notes" } }], skillCase), "wrongInput");
  });

  it("requires the key to be absent when the expected value is null", () => {
    assert.equal(scoreBrainCase([{ name: "start_background_task", input: { goal: "g" } }], noSkillCase), "pass");
    assert.equal(scoreBrainCase([{ name: "start_background_task", input: { goal: "g", skill: "flashcards" } }], noSkillCase), "wrongInput");
  });

  it("scores the tool names first, and a case with no expected input never reads the input", () => {
    assert.equal(scoreBrainCase([{ name: "pause_video", input: { skill: "flashcards" } }], skillCase), "wrongTool");
    assert.equal(scoreBrainCase([], skillCase), "missedTool");
    assert.equal(scoreBrainCase([{ name: "start_background_task", input: { skill: "anything" } }], { ...skillCase, input: undefined }), "pass");
  });

  it("checks every call of the listed tool", () => {
    const twoCalls = [
      { name: "start_background_task", input: { skill: "flashcards" } },
      { name: "start_background_task", input: { skill: "notes" } },
    ];
    assert.equal(scoreBrainCase(twoCalls, skillCase), "wrongInput");
  });
});

describe("withSkills", () => {
  const skills = [{ name: "flashcards", description: "Make flashcards." }];
  const taskTool = toolCatalog.tools.find((tool) => tool.name === "start_background_task") as ToolCatalog["tools"][number];

  it("lists the skills and a skill enum in start_background_task only", () => {
    const withTheSkills = withSkills(taskTool, skills);

    assert.ok(withTheSkills.description.startsWith(taskTool.description));
    assert.ok(withTheSkills.description.includes("flashcards: Make flashcards."));
    assert.deepEqual((withTheSkills.inputSchema.properties as Record<string, { enum?: string[] }>).skill.enum, ["flashcards"]);
    assert.deepEqual(withTheSkills.inputSchema.required, ["goal"]);
    assert.equal(withSkills(taskTool, []), taskTool);
    const otherTool = toolCatalog.tools.find((tool) => tool.name === "hear_task_answer") as ToolCatalog["tools"][number];
    assert.equal(withSkills(otherTool, skills), otherTool);
  });

  it("builds every request with the fixture's skills, and leaves a file with no skills alone", () => {
    const taskToolIn = (file: BrainEvalFile) =>
      requestBodyFor(file.cases.find((brainCase) => brainCase.id === "nothing-research") as BrainCase, file, toolCatalog).tools.find(
        (tool) => tool.name === "start_background_task",
      );

    assert.ok(taskToolIn(evalFile)?.description.includes("flashcards: "));
    assert.equal(taskToolIn({ ...evalFile, skills: undefined })?.description, taskTool.description);
  });

  it("uses the sentences the app source holds", () => {
    const swiftSource = readFileSync(join(dirname(benchDirectory), "leanring-buddy", "VoiceCommandTools.swift"), "utf8");
    // The Swift string literal escapes its quotes and newlines.
    const swiftText = (text: string) => text.replaceAll('"', '\\"');

    assert.ok(swiftSource.includes(swiftText(skillInstructionSentence)), "skillInstructionSentence differs from VoiceCommandTools.swift");
    assert.ok(swiftSource.includes(swiftText(skillInputDescription)), "skillInputDescription differs from VoiceCommandTools.swift");
    assert.ok(swiftSource.includes("Skills, each a fixed procedure for one kind of task:"));
  });
});

describe("acceptedAnswersOf", () => {
  it("reads none as no tool, a name as one tool, and a list as several", () => {
    const brainCase: BrainCase = { id: "x", context: "video", say: "x", why: "x", accept: ["none", "pop_out", ["set_control", "run_simulation"]] };

    assert.deepEqual(acceptedAnswersOf(brainCase), [[], ["pop_out"], ["set_control", "run_simulation"]]);
  });
});

describe("toolCallsIn", () => {
  it("reads tool calls and spoken text from a Worker reply", () => {
    const reply = JSON.stringify({
      content: [
        { type: "text", text: "On it." },
        { type: "tool_use", id: "t1", name: "seek_relative", input: { seconds: -30, confirmation: "back 30" } },
      ],
      stopReason: "tool_use",
    });

    assert.deepEqual(toolCallsIn(reply), {
      toolCalls: [{ name: "seek_relative", input: { seconds: -30, confirmation: "back 30" } }],
      spokenText: "On it.",
    });
  });

  it("reads a reply that is not a Worker reply as no tool", () => {
    assert.deepEqual(toolCallsIn("<html>bad gateway</html>"), { toolCalls: [], spokenText: "" });
    assert.deepEqual(toolCallsIn("[1]"), { toolCalls: [], spokenText: "" });
  });
});

describe("costOfUsageLines", () => {
  const haikuLine = { route: "/voice-command", model: "claude-haiku-5-5", serviceTier: undefined, inputTokens: 1000, cacheWriteTokens: 0, cacheReadTokens: 0, outputTokens: 100 };

  it("prices each line, and is unknown for a request with no usage line or an unpriced model", () => {
    assert.ok(Math.abs((costOfUsageLines([haikuLine]) ?? 0) - (1000 * 0.1 + 100 * 0.5) / 1_000_000) < 1e-12);
    assert.equal(costOfUsageLines([]), null);
    const warn = mock.method(console, "warn", () => undefined);
    assert.equal(costOfUsageLines([haikuLine, { ...haikuLine, model: "claude-unknown-9" }]), null);
    warn.mock.restore();
  });
});

describe("summarizeSamples", () => {
  it("counts each outcome and the pass rate", () => {
    const summary = summarizeSamples([
      sample({ outcome: "pass" }),
      sample({ outcome: "pass" }),
      sample({ outcome: "wrongTool" }),
      sample({ outcome: "missedTool" }),
      sample({ outcome: "spuriousTool" }),
      sample({ outcome: "error" }),
    ]);
    assert.equal(summarizeSamples([sample({ outcome: "wrongInput" }), sample({ outcome: "pass" })]).wrongInput, 1);

    assert.deepEqual(
      [summary.runs, summary.passed, summary.passRate, summary.wrongTool, summary.missedTool, summary.spuriousTool, summary.errors, summary.wrongInput],
      [6, 2, 0.3333, 1, 1, 1, 1, 0],
    );
  });

  it("reads p50 and p95 latency by nearest rank", () => {
    const latencies = [100, 200, 300, 400, 500, 600, 700, 800, 900, 1000];
    const summary = summarizeSamples(latencies.map((totalMs) => sample({ totalMs })));

    assert.equal(summary.p50Ms, 500);
    assert.equal(summary.p95Ms, 1000);
    assert.ok(Number.isNaN(percentile([], 0.5)));
  });

  it("sums the cost, and says unknown when any sample's cost is unknown", () => {
    assert.equal(summarizeSamples([sample({ costUSD: 0.001 }), sample({ costUSD: 0.002 })]).totalCostUSD, 0.003);
    assert.equal(summarizeSamples([sample({ costUSD: 0.001 }), sample({ costUSD: null })]).totalCostUSD, null);
  });

  it("splits samples by context in the fixture's order, with an overall row", () => {
    const summary = summarizeByContext(
      [sample({ context: "video", outcome: "pass" }), sample({ context: "nothing", outcome: "wrongTool" }), sample({ context: "nothing", outcome: "pass" })],
      ["nothing", "video"],
    );

    assert.deepEqual(Object.keys(summary.byContext), ["nothing", "video"]);
    assert.equal(summary.byContext.nothing.passRate, 0.5);
    assert.equal(summary.byContext.video.passRate, 1);
    assert.equal(summary.overall.runs, 3);
  });
});

describe("the fixtures", () => {
  it("validate, with at least 25 cases and at least two in every context", () => {
    validateBrainEvals(evalFile, toolCatalog);

    assert.ok(evalFile.cases.length >= 25, `${evalFile.cases.length} cases`);
    for (const contextName of Object.keys(evalFile.contexts)) {
      assert.ok(evalFile.cases.filter((brainCase) => brainCase.context === contextName).length >= 2, contextName);
    }
  });

  it("cover near misses and a request no tool fits", () => {
    const acceptsNoTool = evalFile.cases.filter((brainCase) => acceptedAnswersOf(brainCase).some((answer) => answer.length === 0));

    assert.ok(acceptsNoTool.length >= 2);
  });

  it("offer animate_picture in the contexts with nothing on screen and no video, as track A defines them", () => {
    assert.ok(evalFile.contexts.nothing.tools.includes("animate_picture"));
    assert.ok(evalFile.contexts.taskAnswer.tools.includes("animate_picture"));
  });

  const approvalInputOf = (brainCase: BrainCase) => brainCase.input?.answer_approval;

  it("cover a yes, a no, and an always while a request waits, and a command that must not answer it", () => {
    const approvalCases = evalFile.cases.filter((brainCase) => brainCase.context === "approvalWaiting");
    const answers = approvalCases.filter((brainCase) => acceptedAnswersOf(brainCase).some((answer) => answer.includes("answer_approval")));

    assert.ok(answers.some((brainCase) => approvalInputOf(brainCase)?.approved === true && approvalInputOf(brainCase)?.always === false));
    assert.ok(answers.some((brainCase) => approvalInputOf(brainCase)?.approved === false));
    assert.ok(answers.some((brainCase) => approvalInputOf(brainCase)?.always === true));
    assert.ok(approvalCases.some((brainCase) => !acceptedAnswersOf(brainCase).flat().includes("answer_approval")), "an unrelated command must not answer the request");
    assert.ok(!evalFile.contexts.nothing.tools.includes("answer_approval"), "answer_approval is offered only while a request waits");
  });

  it("reject a case that names an unknown context, an unoffered tool, or a repeated id", () => {
    const withCase = (brainCase: BrainCase): BrainEvalFile => ({ ...evalFile, cases: [...evalFile.cases, brainCase] });
    const validCase: BrainCase = { id: "new-case", context: "video", say: "pause", why: "x", accept: ["pause_video"] };

    validateBrainEvals(withCase(validCase), toolCatalog);
    assert.throws(() => validateBrainEvals(withCase({ ...validCase, context: "nowhere" }), toolCatalog), /unknown context/);
    assert.throws(() => validateBrainEvals(withCase({ ...validCase, accept: ["show_ready_model"] }), toolCatalog), /does not offer/);
    assert.throws(() => validateBrainEvals(withCase({ ...validCase, id: "video-seek-back" }), toolCatalog), /used twice/);
    assert.throws(
      () => validateBrainEvals(withCase({ ...validCase, input: { start_background_task: { skill: "flashcards" } } }), toolCatalog),
      /no accepted answer calls/,
    );
    assert.throws(
      () => validateBrainEvals(withCase({ ...validCase, toolResults: { show_ready_model: { outcome: "handedOff" } } }), toolCatalog),
      /scripts the result of show_ready_model/,
    );
  });
});

describe("the tool catalog", () => {
  const appCheckout = dirname(benchDirectory);

  it("holds the description the app source holds for every tool the source defines", () => {
    const staleToolNames = toolsWithStaleDescriptions(toolCatalog, descriptionsInAppSource(appCheckout));

    assert.deepEqual(staleToolNames, [], "Run node bench/brainEvals.ts sync-tools, then record a new baseline.");
  });

  it("finds the tools of the app source, so the check above cannot pass by finding nothing", () => {
    const sourceDescriptions = descriptionsInAppSource(appCheckout);

    for (const toolName of ["pop_out", "build_simulation", "record_guess", "start_background_task", "rotate_model", "run_simulation"]) {
      assert.ok(sourceDescriptions[toolName]?.length > 20, toolName);
    }
  });

  it("reads Swift and JavaScript descriptions with their escapes decoded", () => {
    const swiftSource = 'enum AppVoiceTool {\n case popOut = "pop_out"\n struct Context {}\n private var toolDescription: String {\n case .popOut:\n return "Say \\"pop\\" now."\n }\n private var inputSchema {}';
    const javaScriptSource = '{\n name: "zoom",\n description: "Zoom \\"in\\".",\n}';

    assert.deepEqual(appToolDescriptionsIn(swiftSource), { pop_out: 'Say "pop" now.' });
    assert.deepEqual(pageToolDescriptionsIn(javaScriptSource), { zoom: 'Zoom "in".' });
  });

  it("flags a tool whose description differs, and ignores a tool the source does not define", () => {
    const catalog: ToolCatalog = {
      tools: [
        { name: "a", description: "old", inputSchema: { type: "object" }, readOnly: false },
        { name: "b", description: "hand written", inputSchema: { type: "object" }, readOnly: false, handWritten: true },
      ],
    };

    assert.deepEqual(toolsWithStaleDescriptions(catalog, { a: "new" }), ["a"]);
  });
});

// ---------- The harness backend ----------

const fixtureCase = (caseId: string) => evalFile.cases.find((brainCase) => brainCase.id === caseId) as BrainCase;
// Copied from the format string in harness/brain.go's brainUsageLine, with numbers filled in.
const brainGoTurnLine = "Brain: turn 2 on claude-haiku-5-5 stopped for tool_use, tokens in 1200, cache read 3400, cache write 56, out 789, 640 ms";

/** The lines the harness writes for one command, as harness/brainloop.go writes them, with the time each arrives. */
function replay(brainCase: BrainCase, lines: Array<[Record<string, unknown>, number]>) {
  const recorder = new HarnessCommandRecorder(brainCase, "cmd-1");
  const answers = lines.map(([message, elapsedMs]) => recorder.receive(message, elapsedMs));
  return { record: recorder.record, answers };
}
const turn1Line = { type: "log", message: "Brain: turn 1 on claude-haiku-5-5 stopped for tool_use, tokens in 100, cache read 2000, cache write 0, out 50, 400 ms" };
const toolCallLine = (toolUseID: string, name: string, input: Record<string, unknown>, turnIndex: number) => ({
  type: "tool_call",
  taskID: "cmd-1",
  toolUseID,
  name,
  input,
  turnIndex,
});
const finishedLine = (spokenLine: string) => ({ type: "voice_command_finished", taskID: "cmd-1", spokenLine, gaveUp: false });

describe("parseBrainTurnLine", () => {
  it("reads the line harness/brain.go writes for each turn", () => {
    assert.deepEqual(parseBrainTurnLine(brainGoTurnLine), {
      turn: 2,
      model: "claude-haiku-5-5",
      stopReason: "tool_use",
      inputTokens: 1200,
      cacheReadTokens: 3400,
      cacheWriteTokens: 56,
      outputTokens: 789,
      elapsedMs: 640,
    });
  });

  it("ignores every other harness log line", () => {
    assert.equal(parseBrainTurnLine("Brain: command cancelled during turn 1"), null);
    assert.equal(parseBrainTurnLine("Task agent: turn 1 stopped for end_turn, tokens in 1, cache read 2, cache write 3, out 4"), null);
  });

  it("still matches the format string in harness/brain.go, so a changed line fails here instead of reading as a command with no cost", () => {
    const brainSource = readFileSync(join(benchDirectory, "..", "harness", "brain.go"), "utf8");

    assert.ok(brainSource.includes('"Brain: turn %d on %s stopped for %s, tokens in %d, cache read %d, cache write %d, out %d, %d ms"'));
  });
});

describe("standInToolResult", () => {
  const videoCase = fixtureCase("video-seek-back");

  it("answers a lookup with an empty lookedUp result when the case scripts none", () => {
    const answer = standInToolResult("find_moment", videoCase);

    assert.equal(answer.outcome, "lookedUp");
    assert.equal(answer.content, '{"ok":true,"result":[]}');
    assert.equal(answer.isError, false);
  });

  it("answers the case's scripted lookup with its caption lines", () => {
    const answer = standInToolResult("find_moment", fixtureCase("video-find-moment"));

    assert.equal(answer.outcome, "lookedUp");
    assert.deepEqual(JSON.parse(answer.content).result[0], { captions: "so the swim bladder is a gas filled organ that sharks simply do not have", seconds: 98.4 });
  });

  it("hands off the tools whose step in the app is a hand-off, and says a tool that changes the screen changed it", () => {
    const handOffToolNames = ["answer_with_screen", "build_new_scene", "pop_out", "animate_picture", "close_scene", "explain_part", "end_quiz", "show_ready_model", "hear_task_answer", "design_theme"];
    for (const handOffToolName of handOffToolNames) {
      assert.equal(standInToolResult(handOffToolName, videoCase).outcome, "handedOff", handOffToolName);
    }
    assert.deepEqual(standInToolResult("seek_relative", videoCase), { outcome: "changed", content: '{"ok":true,"state":null}', isError: false });
  });

  it("answers a scripted failure as an error with its message", () => {
    const failingCase: BrainCase = { ...videoCase, toolResults: { play_video: { outcome: "failed", error: "The video did not start" } } };

    assert.deepEqual(standInToolResult("play_video", failingCase), {
      outcome: "failed",
      content: '{"error":"The video did not start","ok":false,"state":null}',
      isError: true,
    });
  });
});

describe("the harness backend's scoring", () => {
  const seekCase = fixtureCase("video-seek-back");

  it("scores a recorded tool_call line stream the same as the equivalent Worker reply", () => {
    const workerReply = JSON.stringify({ content: [{ type: "tool_use", name: "seek_relative", input: { seconds: -30, confirmation: "back thirty" } }] });
    const { record } = replay(seekCase, [
      [turn1Line, 410],
      [toolCallLine("call-1", "seek_relative", { seconds: -30 }, 0), 412],
      [finishedLine("back thirty"), 430],
    ]);

    assert.equal(sampleFromHarnessRecord(seekCase, 0, record).outcome, scoreBrainCase(toolCallsIn(workerReply).toolCalls, seekCase));
    assert.equal(sampleFromHarnessRecord(seekCase, 0, record).outcome, "pass");
  });

  it("scores a wrong tool and a spoken reply the way the Worker's scoring does", () => {
    const wrongToolStream = replay(seekCase, [[turn1Line, 410], [toolCallLine("call-1", "pause_video", {}, 0), 412], [finishedLine("paused"), 430]]);
    const spokenStream = replay(seekCase, [[turn1Line, 410], [finishedLine("it is a shark"), 415]]);

    assert.equal(sampleFromHarnessRecord(seekCase, 0, wrongToolStream.record).outcome, "wrongTool");
    const spokenSample = sampleFromHarnessRecord(seekCase, 0, spokenStream.record);
    assert.equal(spokenSample.outcome, "missedTool");
    assert.equal(spokenSample.spokenText, "it is a shark");
  });

  it("scores only the first turn's calls, so a second turn after a lookup changes nothing", () => {
    const momentCase = fixtureCase("video-find-moment");
    const { record } = replay(momentCase, [
      [turn1Line, 410],
      [toolCallLine("call-1", "find_moment", { query: "swim bladder" }, 0), 412],
      [{ type: "log", message: "Brain: turn 2 on claude-haiku-5-5 stopped for tool_use, tokens in 200, cache read 2000, cache write 0, out 70, 380 ms" }, 800],
      [toolCallLine("call-2", "seek_to_time", { seconds: 98 }, 1), 802],
      [finishedLine("going there"), 820],
    ]);

    const sample = sampleFromHarnessRecord(momentCase, 0, record);

    assert.equal(sample.outcome, "pass");
    assert.deepEqual(sample.toolCalls.map((toolCall) => toolCall.name), ["find_moment"]);
    // The first turn ends at its own tool_call line, not at the second turn's.
    assert.equal(sample.totalMs, 412);
    assert.equal(sample.fullCommandMs, 820);
  });

  it("measures the first turn to the first tool_call line and the full command to voice_command_finished", () => {
    const { record } = replay(seekCase, [[turn1Line, 410], [toolCallLine("call-1", "seek_relative", { seconds: -30 }, 0), 412], [finishedLine("back thirty"), 430]]);

    const sample = sampleFromHarnessRecord(seekCase, 0, record);

    assert.equal(sample.totalMs, 412);
    assert.equal(sample.fullCommandMs, 430);
  });

  it("counts a command that calls no tool as ending with its first turn", () => {
    const { record } = replay(seekCase, [[turn1Line, 410], [finishedLine("it is a shark"), 415]]);

    assert.equal(sampleFromHarnessRecord(seekCase, 0, record).totalMs, 415);
  });

  it("records task_failed as an error that keeps its reason, and ignores lines of another command", () => {
    const { record } = replay(seekCase, [
      [{ ...toolCallLine("call-9", "pause_video", {}, 0), taskID: "another-command" }, 100],
      [{ type: "task_failed", taskID: "cmd-1", reason: "the request to Claude failed" }, 200],
    ]);

    const sample = sampleFromHarnessRecord(seekCase, 0, record);

    assert.equal(sample.outcome, "error");
    assert.equal(sample.spokenText, "the request to Claude failed");
    assert.deepEqual(record.toolCalls, []);
  });

  it("answers each tool_call with the outcome the app would give, so a lookup keeps the command going", () => {
    const { answers } = replay(fixtureCase("video-find-moment"), [
      [toolCallLine("call-1", "find_moment", { query: "x" }, 0), 1],
      [toolCallLine("call-2", "pop_out", {}, 1), 2],
    ]);

    assert.equal(answers[0]?.outcome, "lookedUp");
    assert.equal(answers[0]?.toolUseID, "call-1");
    assert.equal(answers[1]?.outcome, "handedOff");
  });
});

describe("driving the harness process", () => {
  const fakeHarness = { command: process.execPath, args: [join(benchDirectory, "fixtures", "fake-brain-harness.ts")] };
  const commandFor = (caseId: string, commandID: string) => voiceCommandMessageFor(fixtureCase(caseId), evalFile, toolCatalog, commandID);

  it("sends the case's words, scene state, and tools as one voice_command", () => {
    const voiceCommand = commandFor("video-seek-back", "cmd-1");

    assert.equal(voiceCommand.type, "voice_command");
    assert.equal(voiceCommand.transcript, "go back 30 seconds");
    assert.deepEqual(voiceCommand.sceneState, evalFile.contexts.video.sceneState);
    assert.deepEqual(voiceCommand.tools, requestBodyFor(fixtureCase("video-seek-back"), evalFile, toolCatalog).tools);
  });

  it("answers a lookup with lookedUp and its caption lines, so the brain takes a second turn, and counts one turn first and both in full", async () => {
    const harnessBrain = await startHarnessBrain(fakeHarness, 1, "s3cret");
    try {
      const momentCase = fixtureCase("video-find-moment");
      const record = await harnessBrain.runCommand(commandFor("video-find-moment", "cmd-1"), momentCase);
      const sample = sampleFromHarnessRecord(momentCase, 0, record);

      // The fake harness's spoken line holds the text it got for the lookup, and then the outcome of the seek.
      const spokenLine = record.ending?.kind === "finished" ? record.ending.spokenLine : "";
      assert.ok(spokenLine.includes("so the swim bladder is a gas filled organ"), spokenLine);
      assert.ok(spokenLine.endsWith('changed {"ok":true,"state":null}'), spokenLine);
      assert.deepEqual(record.toolCalls.map((toolCall) => [toolCall.name, toolCall.turnIndex]), [["find_moment", 0], ["seek_to_time", 1]]);
      assert.equal(sample.outcome, "pass");
      assert.equal(sample.turnCount, 2);
      // claude-haiku-5-5 costs $0.1 per million input tokens, $0.01 cache read, and $0.5 output. Turn 1 used 100, 2000, and 50. Turn 2 used 200, 2000, and 70.
      assert.ok(Math.abs((sample.costUSD ?? NaN) - 0.000055) < 1e-9, String(sample.costUSD));
      assert.ok(Math.abs((sample.fullCommandCostUSD ?? NaN) - 0.00013) < 1e-9, String(sample.fullCommandCostUSD));
      assert.ok((sample.fullCommandMs ?? 0) >= sample.totalMs);
    } finally {
      harnessBrain.stop();
    }
  });

  it("runs one command after another on one process, and records a failed command with its reason", async () => {
    const harnessBrain = await startHarnessBrain(fakeHarness, 1, "s3cret");
    try {
      const turned = await harnessBrain.runCommand(commandFor("video-seek-back", "cmd-1"), fixtureCase("video-seek-back"));
      const failed = await harnessBrain.runCommand({ ...commandFor("video-seek-back", "cmd-2"), transcript: "please fail" }, fixtureCase("video-seek-back"));

      assert.equal(turned.ending?.kind, "finished");
      assert.deepEqual(failed.ending, { kind: "failed", reason: "the request to Claude failed" });
    } finally {
      harnessBrain.stop();
    }
  });

  it("records a harness that dies as a failed command, with the secret scrubbed from its stderr", async () => {
    const dyingHarness = { command: process.execPath, args: ["-e", "console.log(JSON.stringify({type:'ready'})); console.error('boom s3cret'); process.exit(1)"] };
    const harnessBrain = await startHarnessBrain(dyingHarness, 1, "s3cret");
    try {
      const record = await harnessBrain.runCommand(commandFor("video-seek-back", "cmd-1"), fixtureCase("video-seek-back"));

      assert.equal(record.ending?.kind, "failed");
      const reason = record.ending?.kind === "failed" ? record.ending.reason : "";
      assert.match(reason, /exited with code 1/);
      assert.ok(reason.includes("boom [secret]") && !reason.includes("s3cret"), reason);
    } finally {
      harnessBrain.stop();
    }
  });
});

describe("harnessParityGate", () => {
  const workerSummary = summarizeSamples([sample({ totalMs: 1000, costUSD: 0.001 }), sample({ totalMs: 1000, costUSD: 0.001 })]);
  const harnessSummary = (overrides: Partial<BrainSample>) =>
    summarizeSamples([sample({ backend: "harness", totalMs: 1000, costUSD: 0.001, ...overrides }), sample({ backend: "harness", totalMs: 1000, costUSD: 0.001, ...overrides })]);

  it("passes when every harness run passes, p50 is within 100 ms, and cost is within 1.5 times", () => {
    const gate = harnessParityGate(workerSummary, harnessSummary({ totalMs: 1100, costUSD: 0.0015 }));

    assert.equal(gate.passed, true);
    assert.equal(gate.checks.length, 3);
  });

  it("fails on a harness run that does not pass", () => {
    const gate = harnessParityGate(workerSummary, summarizeSamples([sample({ backend: "harness" }), sample({ backend: "harness", outcome: "wrongTool" })]));

    assert.equal(gate.passed, false);
    assert.equal(gate.checks[0].passed, false);
  });

  it("fails when the harness's p50 is more than 100 ms above the Worker's", () => {
    const gate = harnessParityGate(workerSummary, harnessSummary({ totalMs: 1101 }));

    assert.deepEqual(gate.checks.map((check) => check.passed), [true, false, true]);
  });

  it("fails when the first-turn cost is above 1.5 times the Worker's, and when it is unknown", () => {
    assert.deepEqual(harnessParityGate(workerSummary, harnessSummary({ costUSD: 0.0016 })).checks.map((check) => check.passed), [true, true, false]);
    assert.deepEqual(harnessParityGate(workerSummary, harnessSummary({ costUSD: null })).checks.map((check) => check.passed), [true, true, false]);
  });
});

describe("the full-command columns", () => {
  it("reports the full command's p50 and mean cost for harness samples, and null for Worker samples", () => {
    const workerOnly = summarizeSamples([sample({}), sample({})]);
    const harnessOnly = summarizeSamples([
      sample({ backend: "harness", fullCommandMs: 800, fullCommandCostUSD: 0.002 }),
      sample({ backend: "harness", fullCommandMs: 1200, fullCommandCostUSD: 0.004 }),
    ]);

    assert.equal(workerOnly.fullCommandP50Ms, null);
    assert.equal(workerOnly.meanFullCommandCostUSD, null);
    assert.equal(harnessOnly.fullCommandP50Ms, 800);
    assert.equal(harnessOnly.meanFullCommandCostUSD, 0.003);
  });

  it("says unknown when a harness command has no cost, so a failed command never reads as free", () => {
    const summary = summarizeSamples([
      sample({ backend: "harness", fullCommandMs: 800, fullCommandCostUSD: 0.002 }),
      sample({ backend: "harness", fullCommandMs: 900, fullCommandCostUSD: null }),
    ]);

    assert.equal(summary.meanFullCommandCostUSD, null);
  });
});
