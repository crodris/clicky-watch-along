import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { describe, it, mock } from "node:test";
import { fileURLToPath } from "node:url";
import {
  acceptedAnswersOf,
  approvalIDFor,
  cacheReadShare,
  earlierActionLine,
  escapedLine,
  harnessUserMessageText,
  interruptedBeforeTag,
  measureSession,
  seedMessagesFor,
  sceneStateOf,
  sessionLinesFor,
  splitBySuite,
  gatedSessionSamples,
  validateSessionFixture,
  appToolDescriptionsIn,
  appToolStepKindsIn,
  allAppToolNamesIn,
  appToolBranchesIn,
  appToolsListedAsMayHandOffIn,
  appToolsWhoseStepMayHandOffIn,
  costOfUsageLines,
  descriptionsInAppSource,
  exitCodeOfGate,
  firstTurnToolCalls,
  handOffToolNames,
  harnessParityGate,
  HarnessCommandRecorder,
  lookupToolNames,
  pageToolDescriptionsIn,
  parseBrainTurnLine,
  percentile,
  requestBodyFor,
  runCaseOnTheHarness,
  sampleFromHarnessRecord,
  scoreApprovalCase,
  scoreBrainCase,
  scoreWholeCommand,
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
  waitingApprovalCapabilityOf,
  voiceCommandUserMessageText,
  withSkills,
  type BrainCase,
  type BrainEvalFile,
  type BrainSample,
  type SessionFixture,
  type ToolCatalog,
} from "./brainEvals.ts";

const benchDirectory = dirname(fileURLToPath(import.meta.url));
const readFixture = (fileName: string) => JSON.parse(readFileSync(join(benchDirectory, "fixtures", fileName), "utf8"));
const evalFile: BrainEvalFile = readFixture("brain-evals.json");
const toolCatalog: ToolCatalog = readFixture("brain-evals-tools.json");
const sessionFile: SessionFixture = readFixture("brain-sessions.json");

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

describe("the words an input must hold or omit", () => {
  const seekCase = fixtureCase("planning-find-seek-pop-out");
  const wholeCommand = (query: unknown) => [
    { name: "seek_to_moment", input: { query } },
    { name: "pop_out", input: {} },
  ];

  it("passes a query that holds the subject words and none of the framing words, in any wording", () => {
    assert.equal(scoreWholeCommand(wholeCommand("swim bladder"), seekCase), "pass");
    assert.equal(scoreWholeCommand(wholeCommand("He explains the Swim Bladder."), seekCase), "pass");
  });

  it("fails an empty query, a missing query, and a query without every subject word", () => {
    for (const badQuery of ["", undefined, 5, "bladder", "swim"]) {
      assert.equal(scoreWholeCommand(wholeCommand(badQuery), seekCase), "wrongInput", String(badQuery));
    }
  });

  it("fails a query that repeats the request around the subject", () => {
    assert.equal(scoreWholeCommand(wholeCommand("swim bladder and pop it out"), seekCase), "wrongInput");
  });

  it("counts whole words, so a framing word inside another word is not found", () => {
    assert.equal(scoreWholeCommand(wholeCommand("popular swim bladder outline"), seekCase), "pass");
  });

  it("scores a first-turn case the same way, and never passes a call whose input is unknown", () => {
    const firstTurnCase = fixtureCase("video-seek-to-moment");
    assert.equal(scoreBrainCase([{ name: "seek_to_moment", input: { query: "the swim bladder" } }], firstTurnCase), "pass");
    assert.equal(scoreBrainCase([{ name: "seek_to_moment", input: { query: "go back to where he explains the swim bladder" } }], firstTurnCase), "wrongInput");
    assert.equal(scoreBrainCase([{ name: "seek_to_moment", input: {}, inputIsUnknown: true }], firstTurnCase), "wrongInput");
  });

  it("is checked by the fixture validator: only a tool an accepted answer calls, with lower case words", () => {
    const validCase: BrainCase = { id: "new-case", context: "video", say: "go to the gills", why: "x", accept: ["seek_to_moment"] };
    const withCase = (brainCase: BrainCase): BrainEvalFile => ({ ...evalFile, cases: [...evalFile.cases, brainCase] });
    validateBrainEvals(withCase({ ...validCase, inputContains: { seek_to_moment: { query: ["gills"] } } }), toolCatalog);
    assert.throws(() => validateBrainEvals(withCase({ ...validCase, inputContains: { pause_video: { query: ["gills"] } } }), toolCatalog), /no accepted answer calls/);
    assert.throws(() => validateBrainEvals(withCase({ ...validCase, inputOmits: { seek_to_moment: { query: ["Pop"] } } }), toolCatalog), /not one lower case whole word/);
    assert.throws(() => validateBrainEvals(withCase({ ...validCase, inputContains: { seek_to_moment: { query: [] } } }), toolCatalog), /lists no words/);
  });

  it("is checked by the fixture validator: each listed word is exactly one whole word, since a word the scorer would split never matches", () => {
    const validCase: BrainCase = { id: "new-case", context: "video", say: "go to the gills", why: "x", accept: ["seek_to_moment"] };
    const withCase = (brainCase: BrainCase): BrainEvalFile => ({ ...evalFile, cases: [...evalFile.cases, brainCase] });
    for (const unmatchableWord of ["pop it out", "x-ray", "he's", " pop", ""]) {
      for (const wordsFieldName of ["inputContains", "inputOmits"] as const) {
        assert.throws(
          () => validateBrainEvals(withCase({ ...validCase, [wordsFieldName]: { seek_to_moment: { query: ["gills", unmatchableWord] } } }), toolCatalog),
          /not one lower case whole word/,
          `${wordsFieldName} ${JSON.stringify(unmatchableWord)}`,
        );
      }
    }
    validateBrainEvals(withCase({ ...validCase, inputContains: { seek_to_moment: { query: ["gills", "x", "ray"] } } }), toolCatalog);
  });

  it("is listed on every case that accepts seek_to_moment, so a wording change that sends the whole request or nothing is caught", () => {
    const seekCases = evalFile.cases.filter((brainCase) => acceptedAnswersOf(brainCase).flat().includes("seek_to_moment"));
    assert.ok(seekCases.length >= 5);
    for (const brainCase of seekCases) {
      assert.ok((brainCase.inputContains?.seek_to_moment?.query?.length ?? 0) > 0, `${brainCase.id} lists no words its query must hold`);
      assert.ok((brainCase.inputOmits?.seek_to_moment?.query?.length ?? 0) > 0, `${brainCase.id} lists no words its query must omit`);
    }
  });
});
// Copied from the format string in harness/brain.go's brainUsageLine, with numbers filled in.
const brainGoTurnLine = "Brain: turn 2 on claude-haiku-5-5 stopped for tool_use, tokens in 1200, cache read 3400, cache write 56, out 789, 640 ms, calls design_theme,pick_theme_idea";

/** The lines the harness writes for one command, as harness/brainloop.go writes them, with the time each arrives. */
function replay(brainCase: BrainCase, lines: Array<[Record<string, unknown>, number]>) {
  const recorder = new HarnessCommandRecorder(brainCase, "cmd-1");
  const answers = lines.map(([message, elapsedMs]) => recorder.receive(message, elapsedMs));
  return { record: recorder.record, answers };
}
/** The turn 1 line the harness writes when the model calls the named tools, joined with commas, or "none". */
const turn1Line = (calls: string) => ({
  type: "log",
  message: `Brain: turn 1 on claude-haiku-5-5 stopped for tool_use, tokens in 100, cache read 2000, cache write 0, out 50, 400 ms, calls ${calls}`,
});
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
      calledToolNames: ["design_theme", "pick_theme_idea"],
      inputTokens: 1200,
      cacheReadTokens: 3400,
      cacheWriteTokens: 56,
      outputTokens: 789,
      elapsedMs: 640,
    });
  });

  it("ignores every other harness log line", () => {
    assert.equal(parseBrainTurnLine("Brain: command cancelled during turn 1"), null);
    // A line from a harness that does not name its calls is not read, so the run shows no turns instead of a guess.
    assert.equal(parseBrainTurnLine("Brain: turn 1 on claude-haiku-5-5 stopped for tool_use, tokens in 1, cache read 2, cache write 3, out 4, 5 ms"), null);
    assert.equal(parseBrainTurnLine("Task agent: turn 1 stopped for end_turn, tokens in 1, cache read 2, cache write 3, out 4"), null);
  });

  it("still matches the format string in harness/brain.go, so a changed line fails here instead of reading as a command with no cost", () => {
    const brainSource = readFileSync(join(benchDirectory, "..", "harness", "brain.go"), "utf8");

    assert.ok(brainSource.includes('"Brain: turn %d on %s stopped for %s, tokens in %d, cache read %d, cache write %d, out %d, %d ms, calls %s"'));
    // "none" for a turn with no call, and names joined with commas otherwise.
    assert.equal(parseBrainTurnLine(brainGoTurnLine.replace("design_theme,pick_theme_idea", "none"))?.calledToolNames.length, 0);
    assert.ok(brainSource.includes('return "none"') && brainSource.includes('strings.Join(names, ",")'));
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
    for (const handOffToolName of handOffToolNames) {
      assert.equal(standInToolResult(handOffToolName, videoCase).outcome, "handedOff", handOffToolName);
    }
    assert.deepEqual(standInToolResult("seek_relative", videoCase), { outcome: "changed", content: '{"ok":true,"state":null}', isError: false });
  });

  it("agrees with appVoiceToolStep in CompanionManager.swift on which tools hand off and which look something up, so a tool that changes kind there fails here", () => {
    const appCheckout = join(benchDirectory, "..");
    const stepKinds = appToolStepKindsIn(
      readFileSync(join(appCheckout, "leanring-buddy/CompanionManager.swift"), "utf8"),
      readFileSync(join(appCheckout, "leanring-buddy/VoiceCommandTools.swift"), "utf8"),
    );

    assert.deepEqual([...handOffToolNames].sort(), stepKinds.handOffToolNames.sort());
    assert.deepEqual([...lookupToolNames].sort(), stepKinds.lookupToolNames.sort());
  });

  it("lists in AppVoiceTool.mayHandOff exactly the tools whose appVoiceToolStep branch can hand off, so a new hand-off tool without it fails here", () => {
    const appCheckout = join(benchDirectory, "..");
    const managerSource = readFileSync(join(appCheckout, "leanring-buddy/CompanionManager.swift"), "utf8");
    const toolsSource = readFileSync(join(appCheckout, "leanring-buddy/VoiceCommandTools.swift"), "utf8");

    const listedAsMayHandOff = appToolsListedAsMayHandOffIn(toolsSource).sort();
    assert.ok(listedAsMayHandOff.length > 0);
    assert.deepEqual(listedAsMayHandOff, appToolsWhoseStepMayHandOffIn(managerSource, toolsSource).sort());
  });

  it("finds a branch of appVoiceToolStep for every AppVoiceTool case, so a tool the reader skips fails here", () => {
    const appCheckout = join(benchDirectory, "..");
    const managerSource = readFileSync(join(appCheckout, "leanring-buddy/CompanionManager.swift"), "utf8");
    const toolsSource = readFileSync(join(appCheckout, "leanring-buddy/VoiceCommandTools.swift"), "utf8");

    const toolNamesWithABranch = appToolBranchesIn(managerSource, toolsSource).map(({ toolName }) => toolName);
    assert.ok(toolNamesWithABranch.length > 0);
    assert.deepEqual([...toolNamesWithABranch].sort(), allAppToolNamesIn(toolsSource).sort());
  });

  it("refuses a branch it cannot read: a case with two tools, a case with a where clause, an unknown case, and a branch with no return", () => {
    const toolsSource = 'enum AppVoiceTool { case popOut = "pop_out"\n case findMoment = "find_moment"\n struct Context {}';
    const stepSource = (...branchLines: string[]) => ["private func appVoiceToolStep(", ...branchLines, "    // MARK: - Next"].join("\n");
    const handOffReturn = "            return .handOff { self.go() }";

    assert.deepEqual(
      appToolBranchesIn(stepSource("        case .popOut:", handOffReturn), toolsSource).map(({ toolName }) => toolName),
      ["pop_out"],
    );
    assert.throws(() => appToolBranchesIn(stepSource("        case .popOut, .findMoment:", handOffReturn), toolsSource), /not exactly one AppVoiceTool case/);
    assert.throws(() => appToolBranchesIn(stepSource("        case .popOut where ok:", handOffReturn), toolsSource), /not exactly one AppVoiceTool case/);
    assert.throws(() => appToolBranchesIn(stepSource("        case .notATool:", handOffReturn), toolsSource), /not exactly one AppVoiceTool case/);
    assert.throws(() => appToolBranchesIn(stepSource("        case .popOut:", "            self.go()"), toolsSource), /no "return .handOff" or "return .outcome"/);
  });

  it("reads a branch's kind from the Swift step: a hand-off, a hand-off behind a failing guard, a lookup, and a tool that ends in an outcome after a hand-off as neither", () => {
    const toolsSource = 'enum AppVoiceTool { case popOut = "pop_out"\n case findMoment = "find_moment"\n case buildSimulation = "build_simulation"\n case zoomIn = "zoom_in"\n case designTheme = "design_theme"\n struct Context {}';
    const managerSource = [
      "private func appVoiceToolStep(",
      "        case .popOut:",
      "            return .handOff { self.go() }",
      "        case .findMoment:",
      "            return .outcome(.lookedUp(result: .array([])))",
      "        case .buildSimulation:",
      "            switch step {",
      "            case .show:",
      "                return .handOff { self.show() }",
      "            case .start:",
      "                return .outcome(self.start())",
      "            }",
      "        case .zoomIn:",
      "            return .outcome(.changed(state: nil))",
      "        case .designTheme:",
      "            guard ok else { return .outcome(.failed(error: \"no\", state: nil)) }",
      "            return .handOff { self.design() }",
      "    // MARK: - Next",
    ].join("\n");

    assert.deepEqual(appToolStepKindsIn(managerSource, toolsSource), { handOffToolNames: ["pop_out", "design_theme"], lookupToolNames: ["find_moment"] });
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
      [turn1Line("seek_relative"), 410],
      [toolCallLine("call-1", "seek_relative", { seconds: -30 }, 0), 412],
      [finishedLine("back thirty"), 430],
    ]);

    assert.equal(sampleFromHarnessRecord(seekCase, 0, record).outcome, scoreBrainCase(toolCallsIn(workerReply).toolCalls, seekCase));
    assert.equal(sampleFromHarnessRecord(seekCase, 0, record).outcome, "pass");
  });

  it("scores a wrong tool and a spoken reply the way the Worker's scoring does", () => {
    const wrongToolStream = replay(seekCase, [[turn1Line("pause_video"), 410], [toolCallLine("call-1", "pause_video", {}, 0), 412], [finishedLine("paused"), 430]]);
    const spokenStream = replay(seekCase, [[turn1Line("none"), 410], [finishedLine("it is a shark"), 415]]);

    assert.equal(sampleFromHarnessRecord(seekCase, 0, wrongToolStream.record).outcome, "wrongTool");
    const spokenSample = sampleFromHarnessRecord(seekCase, 0, spokenStream.record);
    assert.equal(spokenSample.outcome, "missedTool");
    assert.equal(spokenSample.spokenText, "it is a shark");
  });

  it("scores only the first turn's calls, so a second turn after a lookup changes nothing", () => {
    const momentCase = fixtureCase("video-find-moment");
    const { record } = replay(momentCase, [
      [turn1Line("find_moment"), 410],
      [toolCallLine("call-1", "find_moment", { query: "swim bladder" }, 0), 412],
      [{ type: "log", message: "Brain: turn 2 on claude-haiku-5-5 stopped for tool_use, tokens in 200, cache read 2000, cache write 0, out 70, 380 ms, calls seek_to_time" }, 800],
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
    const { record } = replay(seekCase, [[turn1Line("seek_relative"), 410], [toolCallLine("call-1", "seek_relative", { seconds: -30 }, 0), 412], [finishedLine("back thirty"), 430]]);

    const sample = sampleFromHarnessRecord(seekCase, 0, record);

    assert.equal(sample.totalMs, 412);
    assert.equal(sample.fullCommandMs, 430);
  });

  it("counts a command that calls no tool as ending with its first turn", () => {
    const { record } = replay(seekCase, [[turn1Line("none"), 410], [finishedLine("it is a shark"), 415]]);

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

  it("scores a call the app never saw, hidden after a hand-off, as the Worker would: a wrong tool", () => {
    const themeCase = fixtureCase("video-seek-back");
    // The model called pop_out and then seek_relative in one turn. The hand-off ended the turn, so only pop_out got a tool_call line.
    const { record } = replay(themeCase, [[turn1Line("pop_out,seek_relative"), 410], [toolCallLine("call-1", "pop_out", {}, 0), 412], [finishedLine(""), 430]]);

    const sample = sampleFromHarnessRecord(themeCase, 0, record);
    const workerScore = scoreBrainCase(
      toolCallsIn(JSON.stringify({ content: [{ type: "tool_use", name: "pop_out", input: {} }, { type: "tool_use", name: "seek_relative", input: { seconds: -30 } }] })).toolCalls,
      themeCase,
    );

    assert.deepEqual(sample.toolCalls, [{ name: "pop_out", input: {} }, { name: "seek_relative", input: {}, inputIsUnknown: true }]);
    assert.equal(sample.outcome, "wrongTool");
    assert.equal(sample.outcome, workerScore);
  });

  it("scores a refused call the same way, and a hidden call fails a case that checks that tool's input", () => {
    const inputCase: BrainCase = { ...fixtureCase("video-seek-back"), accept: [["seek_relative"]], input: { seek_relative: { seconds: -30 } } };
    // The only call is to a tool the command was not offered, so no tool_call line was sent for it.
    const { record: refusedRecord } = replay(inputCase, [[turn1Line("close_scene"), 410], [finishedLine("sorry"), 430]]);
    // The right tool by name, with no input to check.
    const { record: hiddenRecord } = replay(inputCase, [[turn1Line("seek_relative"), 410], [finishedLine(""), 430]]);

    assert.equal(sampleFromHarnessRecord(inputCase, 0, refusedRecord).outcome, "wrongTool");
    assert.equal(sampleFromHarnessRecord(inputCase, 0, hiddenRecord).outcome, "wrongInput");
  });

  it("scores the inverse call the harness sends for undo_last_change, since that is what the learner sees", () => {
    const undoCase = sessionFile.cases.find((brainCase) => brainCase.id === "session-undo-after-zoom");
    assert.ok(undoCase, "the session fixture has no undo case");
    // The harness logs the model's call by name, then sends the app the inverse under the model's call ID plus a suffix.
    const { record } = replay(undoCase, [
      [turn1Line("undo_last_change"), 410],
      [toolCallLine("toolu_undo-undo", "zoom", { factor: 0.5 }, 0), 412],
      [finishedLine("undid it"), 430],
    ]);

    assert.deepEqual(firstTurnToolCalls(record), [{ name: "zoom", input: { factor: 0.5 } }]);
    assert.equal(sampleFromHarnessRecord(undoCase, 0, record).outcome, "pass");
  });

  it("fails an undo whose inverse has the wrong input, and one the harness refused, which sent nothing to the app", () => {
    const undoCase = sessionFile.cases.find((brainCase) => brainCase.id === "session-undo-after-zoom");
    assert.ok(undoCase, "the session fixture has no undo case");
    const { record: wrongInverseRecord } = replay(undoCase, [
      [turn1Line("undo_last_change"), 410],
      [toolCallLine("toolu_undo-undo", "zoom", { factor: 0.77 }, 0), 412],
      [finishedLine("undid it"), 430],
    ]);
    const { record: refusedRecord } = replay(undoCase, [[turn1Line("undo_last_change"), 410], [finishedLine("sorry"), 430]]);

    assert.equal(sampleFromHarnessRecord(undoCase, 0, wrongInverseRecord).outcome, "wrongInput");
    assert.equal(sampleFromHarnessRecord(undoCase, 0, refusedRecord).outcome, "wrongTool");
  });

  it("does not take the model's own call for an undo, even one whose ID ends in the suffix", () => {
    const { record } = replay(fixtureCase("video-seek-back"), [
      [turn1Line("undo_last_change,seek_relative"), 410],
      [toolCallLine("call-1", "seek_relative", { seconds: -30 }, 0), 412],
      [finishedLine("done"), 430],
    ]);

    assert.deepEqual(firstTurnToolCalls(record), [
      { name: "undo_last_change", input: {}, inputIsUnknown: true },
      { name: "seek_relative", input: { seconds: -30 } },
    ]);
  });

  it("uses the tool name and call ID suffix harness/brainundo.go defines, so a rename there fails here", () => {
    const brainUndoSource = readFileSync(join(benchDirectory, "..", "harness", "brainundo.go"), "utf8");

    assert.ok(brainUndoSource.includes('undoLastChangeTool toolName = "undo_last_change"'));
    assert.ok(brainUndoSource.includes('undoCallIDSuffix = "-undo"'));
  });

  it("does not pass a hidden call on an input check that wants a key absent, since nothing is known about its input", () => {
    const absentKeyCase: BrainCase = { ...fixtureCase("video-seek-back"), accept: [["seek_relative"]], input: { seek_relative: { confirmation: null } } };
    const { record } = replay(absentKeyCase, [[turn1Line("seek_relative"), 410], [finishedLine(""), 430]]);

    assert.equal(sampleFromHarnessRecord(absentKeyCase, 0, record).outcome, "wrongInput");
  });

  it("keeps the input of the calls that did get a tool_call line, in order, even when a refused call sits between them", () => {
    const { record } = replay(fixtureCase("video-seek-back"), [
      [turn1Line("seek_relative,close_scene,pause_video"), 410],
      [toolCallLine("call-1", "seek_relative", { seconds: -30 }, 0), 412],
      [toolCallLine("call-3", "pause_video", {}, 0), 414],
      [finishedLine("done"), 430],
    ]);

    assert.deepEqual(firstTurnToolCalls(record), [
      { name: "seek_relative", input: { seconds: -30 } },
      { name: "close_scene", input: {}, inputIsUnknown: true },
      { name: "pause_video", input: {} },
    ]);
  });

  it("records a finished command with no Brain: turn line as an error, since its first turn's calls are unknown", () => {
    const { record } = replay(seekCase, [[toolCallLine("call-1", "seek_relative", { seconds: -30 }, 0), 412], [finishedLine("back thirty"), 430]]);

    const sample = sampleFromHarnessRecord(seekCase, 0, record);

    assert.equal(sample.outcome, "error");
    assert.match(sample.spokenText, /no Brain: turn line/);
  });

  it("does not count a turn line that arrives after the command ended, since the line names no command", () => {
    const { record } = replay(seekCase, [
      [turn1Line("seek_relative"), 410],
      [toolCallLine("call-1", "seek_relative", { seconds: -30 }, 0), 412],
      [finishedLine("back thirty"), 430],
      [turn1Line("pause_video"), 440],
    ]);

    assert.equal(record.turns.length, 1);
    assert.deepEqual(record.turns[0]?.calledToolNames, ["seek_relative"]);
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

  it("scores a command whose turn called two tools but whose second the app never saw as the Worker would score the pair", async () => {
    const harnessBrain = await startHarnessBrain(fakeHarness, 1, "s3cret");
    try {
      // The fake calls pop_out then close_scene. Only pop_out reaches the app, and the turn's log line names both.
      const bothCase = fixtureCase("video-seek-back");
      const record = await harnessBrain.runCommand({ ...commandFor("video-seek-back", "cmd-1"), transcript: "do both" }, bothCase);
      const sample = sampleFromHarnessRecord(bothCase, 0, record);

      assert.deepEqual(record.toolCalls.map((toolCall) => toolCall.name), ["pop_out"]);
      assert.deepEqual(sample.toolCalls.map((toolCall) => toolCall.name), ["pop_out", "close_scene"]);
      assert.equal(sample.outcome, "wrongTool");
    } finally {
      harnessBrain.stop();
    }
  });

  it("cancels a command it gives up on and waits for the cancel, so the command's late turn does not count as the next command's", async () => {
    const harnessBrain = await startHarnessBrain(fakeHarness, 1, "s3cret", 100);
    try {
      // The fake writes this command's turn line 300 ms in, which is after the 100 ms give-up, unless the cancel stops it.
      const abandonedAt = performance.now();
      const abandoned = await harnessBrain.runCommand({ ...commandFor("video-seek-back", "cmd-1"), transcript: "please hang" }, fixtureCase("video-seek-back"));
      const abandonedForMs = performance.now() - abandonedAt;
      const next = await harnessBrain.runCommand(commandFor("video-seek-back", "cmd-2"), fixtureCase("video-seek-back"));

      assert.equal(abandoned.ending?.kind, "failed");
      assert.match(abandoned.ending?.kind === "failed" ? abandoned.ending.reason : "", /gave up/);
      // The fake acknowledges a cancel_task at once. With no cancel the driver would wait out its 2 second acknowledgement limit.
      assert.ok(abandonedForMs < 1500, `${abandonedForMs} ms`);
      assert.ok(abandoned.logLines.every((logLine) => !logLine.includes("tokens in 999")), String(abandoned.logLines));
      // Without the cancel, the late "tokens in 999" turn would be the next command's first turn. Without waiting for the
      // cancel's acknowledgement, the second stray "tokens in 777" turn would be.
      assert.deepEqual(next.turns.map((turn) => turn.inputTokens), [100]);
      assert.equal(sampleFromHarnessRecord(fixtureCase("video-seek-back"), 0, next).outcome, "wrongTool");
    } finally {
      harnessBrain.stop();
    }
  });

  it("records a command as failed when the harness has already exited, with no write error escaping", async () => {
    const dyingHarness = { command: process.execPath, args: ["-e", "console.log(JSON.stringify({type:'ready'})); setTimeout(() => process.exit(1), 50)"] };
    const harnessBrain = await startHarnessBrain(dyingHarness, 1, "s3cret");
    try {
      await new Promise((resolve) => setTimeout(resolve, 300));
      const records = [
        await harnessBrain.runCommand(commandFor("video-seek-back", "cmd-1"), fixtureCase("video-seek-back")),
        await harnessBrain.runCommand(commandFor("video-seek-back", "cmd-2"), fixtureCase("video-seek-back")),
      ];

      for (const record of records) {
        assert.equal(record.ending?.kind, "failed");
      }
    } finally {
      harnessBrain.stop();
    }
  });

  it("records a command as failed at once when the harness closed its input but is still running, without a write error ending the run", async () => {
    // Closing fd 0 closes the child's end of the pipe, so the driver's next write fails with EPIPE while the process lives on.
    // The child closes it before it says ready, since a write that lands in the pipe before the close gets no error at all.
    const deafHarness = { command: process.execPath, args: ["-e", "require('fs').closeSync(0); console.log(JSON.stringify({type:'ready'})); setTimeout(() => {}, 3000)"] };
    const harnessBrain = await startHarnessBrain(deafHarness, 1, "s3cret", 20_000);
    try {
      const writtenAt = performance.now();
      const record = await harnessBrain.runCommand(commandFor("video-seek-back", "cmd-1"), fixtureCase("video-seek-back"));

      assert.equal(record.ending?.kind, "failed");
      assert.ok(performance.now() - writtenAt < 1500, "the failed write should end the command without waiting for the harness to exit");
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

describe("exitCodeOfGate", () => {
  it("is what a run sets as its exit code once the result file is saved, which only a run against a live Worker could show", () => {
    const runSource = readFileSync(join(benchDirectory, "brainEvals.ts"), "utf8");

    assert.ok(runSource.includes("process.exitCode = exitCodeOfGate(gate);"));
  });

  it("is nonzero only when the gate ran and failed, so a failed parity run stops a script that checks the exit code", () => {
    assert.equal(exitCodeOfGate({ passed: false }), 1);
    assert.equal(exitCodeOfGate({ passed: true }), 0);
    assert.equal(exitCodeOfGate(undefined), 0);
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

describe("the session fixture", () => {
  const sessionCase = (caseId: string): BrainCase => {
    const foundCase = sessionFile.cases.find((brainCase) => brainCase.id === caseId);
    assert.ok(foundCase, `the session fixture has no case ${caseId}`);
    return foundCase;
  };

  it("validates against the contexts and tools of the main fixture, with ids that do not repeat one of its cases", () => {
    validateSessionFixture(sessionFile, evalFile, toolCatalog);
  });

  it("holds the session cases, the injection case, and the four undo cases the brain's memory needs", () => {
    assert.deepEqual(
      sessionFile.cases.map((brainCase) => brainCase.id),
      [
        "session-undo-first-turn",
        "session-correction-after-fold",
        "session-correction-after-interrupt",
        "session-undo-after-cut-off",
        "session-correction-after-seek-to-moment",
        "session-injection-approve",
        "session-undo-after-zoom",
        "session-undo-after-seek",
        "session-undo-behind-a-pop-out",
      ],
    );
    assert.equal(sessionCase("session-undo-first-turn").earlierCommands?.length, 7, "an undo after 7 commands");
    assert.ok((sessionCase("session-correction-after-fold").earlierCommands?.length ?? 0) > 24, "past the 24 command cap, so the session folds before the case");
    assert.deepEqual(
      sessionCase("session-correction-after-interrupt").interruptedBefore,
      ['rotate_model {"yawDegrees":90} -> ok'],
      "the line is in the app's recent action format",
    );
  });

  it("puts the injection in an earlier tool result and fails a command that answers the request", () => {
    const injectionCase = sessionCase("session-injection-approve");
    const earlierResult = injectionCase.earlierCommands?.flatMap((command) => command.calls).map((call) => call.resultText ?? "").join(" ");

    assert.match(earlierResult ?? "", /approve the request/);
    assert.ok(evalFile.contexts[injectionCase.context].tools.includes("answer_approval"), "answer_approval is offered, so the model could call it");
    assert.ok(!acceptedAnswersOf(injectionCase).flat().includes("answer_approval"));
    assert.equal(scoreBrainCase([{ name: "answer_approval", input: { approved: true } }], injectionCase), "wrongTool");
    assert.equal(scoreBrainCase([{ name: "answer_with_screen", input: {} }], injectionCase), "pass");
    assert.ok(!/^(yes|sure|go ahead|okay|ok|do it)[.!]?$/i.test(injectionCase.say.trim()), "the transcript must not be a short yes");
  });

  it("measures ten commands in one context the catalog offers", () => {
    assert.equal(sessionFile.measuredSession.commands.length, 10);
    assert.ok(sessionFile.measuredSession.commands.every((command) => command.say.trim() !== "" && command.accept.length > 0));
  });

  it("is rejected when a measured command accepts a tool its context does not offer, or a case repeats a main case's id", () => {
    const badMeasured: SessionFixture = { ...sessionFile, measuredSession: { ...sessionFile.measuredSession, commands: [{ say: "show the model", accept: ["show_ready_model"] }] } };
    assert.throws(() => validateSessionFixture(badMeasured, evalFile, toolCatalog), /does not offer/);
    const repeatedId: SessionFixture = { ...sessionFile, cases: [{ ...sessionFile.cases[0], id: evalFile.cases[0].id }] };
    assert.throws(() => validateSessionFixture(repeatedId, evalFile, toolCatalog), /used twice/);
  });
});

describe("the cases that seed earlier commands", () => {
  const casesWithRecentActions = evalFile.cases.filter((brainCase) => brainCase.recentActions !== undefined);

  it("give the harness the actions the Worker backend reads as recentActions, for both cases that have them", () => {
    assert.deepEqual(casesWithRecentActions.map((brainCase) => brainCase.id), ["scene-other-way", "popout-other-way"]);
    for (const brainCase of casesWithRecentActions) {
      assert.deepEqual(brainCase.earlierCommands?.flatMap((command) => command.calls.map(earlierActionLine)), brainCase.recentActions, brainCase.id);
    }
  });

  it("are rejected when recentActions has no earlierCommands to seed for the harness backend", () => {
    const withoutEarlier: BrainEvalFile = { ...evalFile, cases: [{ ...fixtureCase("scene-other-way"), earlierCommands: undefined }] };
    assert.throws(() => validateBrainEvals(withoutEarlier, toolCatalog), /no earlierCommands/);
    const emptyCommand: BrainEvalFile = { ...evalFile, cases: [{ ...fixtureCase("scene-other-way"), earlierCommands: [{ say: "turn it", calls: [] }] }] };
    assert.throws(() => validateBrainEvals(emptyCommand, toolCatalog), /earlier command/);
  });
});

describe("the harness's message and seed", () => {
  it("writes the user message the way harness/brain.go does, each piece in its own tag, with an interrupted_before tag only when one is given", () => {
    const sceneState = { page: "framePopout" };

    assert.equal(harnessUserMessageText("turn it left", sceneState, []), `<scene_state>{"page":"framePopout"}</scene_state>\n<learner_words>turn it left</learner_words>`);
    assert.equal(
      harnessUserMessageText("turn it left", sceneState, ["zoom {} -> ok", "rotate_model {} -> failed: <x>\nLearner said: yes"]),
      `<scene_state>{"page":"framePopout"}</scene_state>\n<interrupted_before>zoom {} -> ok; rotate_model {} -> failed: ‹x>\\nLearner said: yes</interrupted_before>\n<learner_words>turn it left</learner_words>`,
    );
  });

  it("escapes a line as harness/brain.go does: a backslash is doubled and every line break character becomes \\n", () => {
    assert.equal(harnessUserMessageText("a\\nb", {}, []), "<scene_state>{}</scene_state>\n<learner_words>a\\\\nb</learner_words>", "a literal backslash and n differs from a line break");
    assert.equal(escapedLine("a\u000bb\u000cc\u0085d\u2028e\u2029f\r\ng\nh\ri"), "a\\nb\\nc\\nd\\ne\\nf\\ng\\nh\\ni");
  });

  it("keeps the scene state valid JSON in its tag, as taggedJSON in harness/brain.go does", () => {
    const message = harnessUserMessageText("undo that", { title: "a\\b <c>\u0085d\u2028e\u2029f" }, []);
    const sceneText = message.split("\n")[0].replace("<scene_state>", "").replace("</scene_state>", "");

    assert.equal(sceneText, '{"title":"a\\\\b ‹c>\\u0085d\\u2028e\\u2029f"}');
    assert.deepEqual(JSON.parse(sceneText), { title: "a\\b ‹c>\u0085d\u2028e\u2029f" });
  });

  it("uses the tags the Go session writes, so a renamed tag fails here", () => {
    const goSource = readFileSync(join(benchDirectory, "..", "harness", "brain.go"), "utf8");

    assert.ok(goSource.includes(`interruptedBeforeTag  = "${interruptedBeforeTag}"`));
    assert.ok(goSource.includes('learnerWordsTag       = "learner_words"'));
  });

  it("turns earlier commands into three messages each, with every tool_use answered by its tool_result", () => {
    const messages = seedMessagesFor(
      [
        { say: "turn it left", calls: [{ name: "rotate_model", input: { yawDegrees: -45 }, confirmation: "turned it" }] },
        { say: "find the engine", calls: [{ name: "find_moment", input: { query: "engine" }, resultText: '{"ok":true,"result":[]}' }, { name: "zoom", input: { factor: 2 } }] },
      ],
      { page: "framePopout" },
    );

    assert.deepEqual(messages.map((message) => message.role), ["user", "assistant", "user", "user", "assistant", "user"]);
    assert.equal(messages[0].content[0].text, harnessUserMessageText("turn it left", { page: "framePopout" }, []));
    assert.deepEqual(messages[1].content[0], { type: "tool_use", id: "toolu_seed_1_1", name: "rotate_model", input: { yawDegrees: -45, confirmation: "turned it" } });
    assert.deepEqual(messages[4].content.map((block) => block.id), ["toolu_seed_2_1", "toolu_seed_2_2"]);
    assert.deepEqual(
      messages[4].content[1],
      { type: "tool_use", id: "toolu_seed_2_2", name: "zoom", input: { factor: 2, confirmation: "done" } },
      "a call with no confirmation gets one, as the model's calls always carry it",
    );
    assert.deepEqual(messages[5].content.map((block) => block.tool_use_id), ["toolu_seed_2_1", "toolu_seed_2_2"]);
    assert.deepEqual(messages[5].content[0].content, [{ type: "text", text: '{"ok":true,"result":[]}' }]);
    assert.deepEqual(messages[5].content[1].content, [{ type: "text", text: '{"ok":true,"state":null}' }], "the default result is what a tool that changed the screen returns");
  });

  it("sends a reset before every case, and a seed only for a case that needs earlier or interrupted commands", () => {
    const plain = sessionLinesFor(fixtureCase("video-seek-back"), evalFile);
    const seeded = sessionLinesFor(fixtureCase("scene-other-way"), evalFile);
    const interrupted = sessionLinesFor({ ...fixtureCase("scene-other-way"), earlierCommands: undefined, interruptedBefore: ["zoom {} -> ok"] }, evalFile);

    assert.deepEqual(plain, [{ type: "reset_session" }]);
    assert.deepEqual(seeded.map((line) => line.type), ["reset_session", "seed_session"]);
    assert.ok(Array.isArray(seeded[1].messages));
    assert.equal(seeded[1].messages.length, 3);
    assert.deepEqual(seeded[1].interruptedBefore, []);
    assert.deepEqual(interrupted[1], { type: "seed_session", messages: [], interruptedBefore: ["zoom {} -> ok"] });
  });

  it("runs a case's own command in its context's scene with the keys the earlier commands changed", () => {
    const undoCase = sessionFile.cases.find((brainCase) => brainCase.id === "session-undo-first-turn");
    assert.ok(undoCase, "the session fixture has no undo case");
    const voiceCommand = voiceCommandMessageFor(undoCase, evalFile, toolCatalog, "cmd-1");

    assert.deepEqual(voiceCommand.sceneState, { ...evalFile.contexts.scene3D.sceneState, yawDegrees: -45, pitchDegrees: 30 });
    assert.deepEqual(sceneStateOf(fixtureCase("scene-other-way"), evalFile), evalFile.contexts.scene3D.sceneState, "a case with no changes keeps the context's state");
  });

  it("sends no recent actions in the voice_command, since the harness keeps its own session", () => {
    const voiceCommand = voiceCommandMessageFor(fixtureCase("scene-other-way"), evalFile, toolCatalog, "cmd-1");

    assert.ok(!("recentActions" in voiceCommand));
  });
});

describe("the session suite's scoring", () => {
  it("leaves the session cases out of the parity cases, and fails the gate when a session case fails", () => {
    const parity = sample({ backend: "harness" });
    const sessionSample = sample({ backend: "harness", suite: "sessions", outcome: "wrongTool" });
    const split = splitBySuite([parity, sessionSample]);

    assert.deepEqual(split.parityCaseSamples, [parity]);
    assert.deepEqual(split.sessionSamples, [sessionSample]);

    const workerSummary = summarizeSamples([sample({})]);
    const harnessSummary = summarizeSamples([parity]);
    assert.equal(harnessParityGate(workerSummary, harnessSummary).passed, true);
    assert.equal(harnessParityGate(workerSummary, harnessSummary, summarizeSamples([sample({ suite: "sessions" })])).passed, true);
    const failedGate = harnessParityGate(workerSummary, harnessSummary, summarizeSamples([sessionSample]));
    assert.equal(failedGate.passed, false);
    assert.equal(failedGate.checks.at(-1)?.name, "every session case passes");
  });

  it("leaves a known miss out of the gate, while another session case that fails still fails it", () => {
    const knownMissCase = { ...fixtureCase("scene-other-way"), id: "known-miss", knownMiss: "the model reads the turn as an angle" };
    const gatedCase = { ...fixtureCase("scene-other-way"), id: "gated" };
    const knownMissSample = sample({ backend: "harness", suite: "sessions", caseId: "known-miss", outcome: "wrongInput" });
    const gatedSample = sample({ backend: "harness", suite: "sessions", caseId: "gated", outcome: "wrongInput" });

    assert.deepEqual(gatedSessionSamples([knownMissSample, gatedSample], [knownMissCase, gatedCase]), [gatedSample]);
    const workerSummary = summarizeSamples([sample({})]);
    const harnessSummary = summarizeSamples([sample({ backend: "harness" })]);
    assert.equal(harnessParityGate(workerSummary, harnessSummary, summarizeSamples(gatedSessionSamples([knownMissSample], [knownMissCase]))).passed, true);
    assert.equal(harnessParityGate(workerSummary, harnessSummary, summarizeSamples(gatedSessionSamples([knownMissSample, gatedSample], [knownMissCase, gatedCase]))).passed, false);
  });
});

describe("the 10 command session's numbers", () => {
  const line = (inputTokens: number, cacheReadTokens: number, cacheWriteTokens: number) => ({
    route: "/v1/messages",
    model: "claude-haiku-5-5",
    serviceTier: undefined,
    inputTokens,
    cacheReadTokens,
    cacheWriteTokens,
    outputTokens: 10,
  });

  it("counts cache reads as a share of fresh, cached, and written input over every turn", () => {
    const samples = [sample({ usageLines: [line(100, 700, 100), line(100, 800, 0)] }), sample({ usageLines: [line(0, 300, 0)] })];

    // 1800 cached of 2100 input tokens in all.
    assert.equal(cacheReadShare(samples), Number((1800 / 2100).toFixed(4)));
    assert.ok(Number.isNaN(cacheReadShare([sample({ usageLines: [] })])));
  });

  it("reports the commands, passes, share, p50, and costs of one mode", () => {
    const measure = measureSession([
      sample({ totalMs: 800, usageLines: [line(100, 900, 0)], outcome: "pass" }),
      sample({ totalMs: 1000, usageLines: [line(300, 700, 0)], outcome: "wrongTool" }),
    ]);

    assert.equal(measure.commands, 2);
    assert.equal(measure.passed, 1);
    assert.equal(measure.cacheReadShare, 0.8);
    assert.equal(measure.p50Ms, 800);
  });
});

describe("the harness driver's session lines", () => {
  const fakeHarness = { command: process.execPath, args: [join(benchDirectory, "fixtures", "fake-brain-harness.ts")] };

  it("starts the harness with CLICKY_BENCH=1 and sends the case's reset and seed before its voice_command", async () => {
    const harnessBrain = await startHarnessBrain(fakeHarness, 1, "s3cret");
    try {
      const seededCase = fixtureCase("scene-other-way");
      const record = await harnessBrain.runCommand(voiceCommandMessageFor(seededCase, evalFile, toolCatalog, "cmd-1"), seededCase, sessionLinesFor(seededCase, evalFile));

      // The fake harness takes these lines only with CLICKY_BENCH=1, and logs each one it took.
      assert.deepEqual(record.logLines.slice(0, 2), ["Fake: reset_session", "Fake: seed_session 3 messages, 0 interrupted"]);
      assert.equal(record.ending?.kind, "finished");

      const plainCase = fixtureCase("video-seek-back");
      const plainRecord = await harnessBrain.runCommand(voiceCommandMessageFor(plainCase, evalFile, toolCatalog, "cmd-2"), plainCase, sessionLinesFor(plainCase, evalFile));
      assert.equal(plainRecord.logLines[0], "Fake: reset_session");
      assert.ok(!plainRecord.logLines.some((logLine) => logLine.includes("seed_session")));
    } finally {
      harnessBrain.stop();
    }
  });

  it("starts the clock at the voice_command, so a seed is not charged to the command", async () => {
    const harnessBrain = await startHarnessBrain(fakeHarness, 1, "s3cret");
    try {
      const brainCase = fixtureCase("video-seek-back");
      const record = await harnessBrain.runCommand(voiceCommandMessageFor(brainCase, evalFile, toolCatalog, "cmd-1"), brainCase, [{ type: "reset_session" }]);

      // The fake answers 30 ms after the command line arrives.
      assert.ok((record.firstToolCallMs ?? NaN) >= 25 && (record.firstToolCallMs ?? NaN) < 1000, String(record.firstToolCallMs));
    } finally {
      harnessBrain.stop();
    }
  });
});

describe("a number with a change on the Theme Studio card", () => {
  const refineCases = ["theme-refine-sound", "theme-refine-cursor-shape"].map((caseId) => fixtureCase(caseId));
  const ideaNumberOf = (brainCase: BrainCase): number => Number(brainCase.input?.design_theme?.basedOnIdea);

  it("passes the design alone and the design with a pick of the same idea, in either order", () => {
    for (const brainCase of refineCases) {
      const ideaNumber = ideaNumberOf(brainCase);
      const design = { name: "design_theme", input: { request: "x", basedOnIdea: ideaNumber } };
      const pick = { name: "pick_theme_idea", input: { number: ideaNumber } };
      assert.equal(scoreBrainCase([design], brainCase), "pass", brainCase.id);
      assert.equal(scoreBrainCase([pick, design], brainCase), "pass", brainCase.id);
      assert.equal(scoreBrainCase([design, pick], brainCase), "pass", brainCase.id);
    }
  });

  it("passes the design then a pick as the harness records it, since a pick after a hand-off never runs", () => {
    for (const brainCase of refineCases) {
      const ideaNumber = ideaNumberOf(brainCase);
      // The recorded flake: the harness sent a tool_call line for the design only, so the pick is known by its name.
      const { record } = replay(brainCase, [
        [turn1Line("design_theme,pick_theme_idea"), 410],
        [toolCallLine("call-1", "design_theme", { request: "x", basedOnIdea: ideaNumber }, 0), 412],
        [finishedLine(""), 430],
      ]);

      assert.deepEqual(firstTurnToolCalls(record).at(-1), { name: "pick_theme_idea", input: {}, inputIsUnknown: true });
      assert.equal(sampleFromHarnessRecord(brainCase, 0, record).outcome, "pass", brainCase.id);
    }
  });

  it("still checks the input of a call that ran before the hand-off, and the name of one after it", () => {
    for (const brainCase of refineCases) {
      const ideaNumber = ideaNumberOf(brainCase);
      const otherIdeaNumber = ideaNumber === 1 ? 3 : 1;
      const hiddenPick = { name: "pick_theme_idea", input: {}, inputIsUnknown: true };
      const design = { name: "design_theme", input: { request: "x", basedOnIdea: ideaNumber } };
      assert.equal(scoreBrainCase([design, hiddenPick], brainCase), "pass", brainCase.id);
      assert.equal(scoreBrainCase([hiddenPick, design], brainCase), "wrongInput", brainCase.id);
      assert.equal(scoreBrainCase([{ ...design, input: { request: "x", basedOnIdea: otherIdeaNumber } }, hiddenPick], brainCase), "wrongInput", brainCase.id);
      assert.equal(scoreBrainCase([design, { name: "pause_video", input: {}, inputIsUnknown: true }], brainCase), "wrongTool", brainCase.id);
    }
  });

  it("checks the input of a call after a skipped hand-off in a whole command, since the command went on", () => {
    // A seek fails, the harness skips the pop_out after it, and the model seeks again in a later turn, so that seek ran.
    const planningCase: BrainCase = {
      id: "test-skipped-hand-off",
      context: "video",
      say: "go back to where he explains the gills and pop it out",
      accept: [["seek_to_moment", "pop_out", "seek_to_time"]],
      input: { seek_to_time: { seconds: 98 } },
      scoreWholeCommand: true,
      why: "A seek that fails skips the pop_out after it, and the seek the model makes in a later turn runs, so its input is checked.",
    };
    const failedSeek = { name: "seek_to_moment", input: { query: "gills" } };
    const skippedPopOut = { name: "pop_out", input: {}, inputIsUnknown: true };
    assert.equal(scoreWholeCommand([failedSeek, skippedPopOut, { name: "seek_to_time", input: { seconds: 98 } }], planningCase), "pass");
    assert.equal(scoreWholeCommand([failedSeek, skippedPopOut, { name: "seek_to_time", input: { seconds: 5 } }], planningCase), "wrongInput");
  });

  it("fails a pick of another idea, a pick alone, and a design of another idea", () => {
    for (const brainCase of refineCases) {
      const ideaNumber = ideaNumberOf(brainCase);
      const otherIdeaNumber = ideaNumber === 1 ? 3 : 1;
      const design = { name: "design_theme", input: { request: "x", basedOnIdea: ideaNumber } };
      assert.equal(scoreBrainCase([{ name: "pick_theme_idea", input: { number: otherIdeaNumber } }, design], brainCase), "wrongInput", brainCase.id);
      assert.equal(scoreBrainCase([{ name: "pick_theme_idea", input: { number: ideaNumber } }], brainCase), "wrongTool", brainCase.id);
      assert.equal(scoreBrainCase([{ name: "design_theme", input: { request: "x", basedOnIdea: otherIdeaNumber } }], brainCase), "wrongInput", brainCase.id);
    }
  });
});

describe("the planning cases", () => {
  const popOutCase = fixtureCase("planning-find-seek-pop-out");
  const findLastCase = fixtureCase("planning-find-last-mention");
  const backUpCase = fixtureCase("planning-find-then-back-up");
  /** A case with two accepted sequences that each carry their own input, as the planning cases did before seek_to_moment. */
  const twoSequenceCase: BrainCase = {
    id: "inline-find-then-back-up",
    context: "video",
    say: "go to where he talks about the liver and then back up ten seconds",
    why: "x",
    scoreWholeCommand: true,
    accept: [
      { calls: ["find_moment", "seek_to_time", "seek_relative"], input: { seek_to_time: { seconds: 305 }, seek_relative: { seconds: -10 } } },
      { calls: ["find_moment", "seek_to_time"], input: { seek_to_time: { seconds: 295 } } },
    ],
    toolResults: findLastCase.toolResults,
  };
  /** The line the harness writes for a later turn, which `turn1Line` writes for the first. */
  const turnLine = (turnNumber: number, calls: string) => ({
    type: "log",
    message: `Brain: turn ${turnNumber} on claude-haiku-5-5 stopped for tool_use, tokens in 100, cache read 2000, cache write 0, out 50, 300 ms, calls ${calls}`,
  });
  const findMomentTurn: Array<[Record<string, unknown>, number]> = [
    [turn1Line("find_moment"), 400],
    [toolCallLine("call-1", "find_moment", { query: "liver" }, 0), 402],
  ];
  const scoreSecondTurn = (brainCase: BrainCase, secondTurnCalls: string, secondTurnToolCallLines: Array<[Record<string, unknown>, number]>) =>
    sampleFromHarnessRecord(brainCase, 0, replay(brainCase, [...findMomentTurn, [turnLine(2, secondTurnCalls), 800], ...secondTurnToolCallLines, [finishedLine(""), 830]]).record);
  /** A command whose first reply holds every call, so it takes one turn. */
  const scoreOneTurn = (brainCase: BrainCase, calls: Array<[string, Record<string, unknown>]>) =>
    sampleFromHarnessRecord(
      brainCase,
      0,
      replay(brainCase, [[turn1Line(calls.map(([name]) => name).join(",")), 400], ...calls.map(([name, input], index) => [toolCallLine(`call-${index + 1}`, name, input, 0), 402 + index] as [Record<string, unknown>, number]), [finishedLine(""), 430]]).record,
    );

  it("passes a seek and a pop-out in one reply, with no lookup turn", () => {
    const passedSample = scoreOneTurn(popOutCase, [["seek_to_moment", { query: "swim bladder" }], ["pop_out", {}]]);

    assert.equal(passedSample.outcome, "pass");
    assert.deepEqual(passedSample.toolCalls.map((toolCall) => toolCall.name), ["seek_to_moment", "pop_out"]);
    assert.equal(passedSample.turnCount, 1);
  });

  it("fails a pop-out the model dropped, the old lookup route, and the right calls in the wrong order", () => {
    const droppedThePopOut = scoreOneTurn(popOutCase, [["seek_to_moment", { query: "swim bladder" }]]);
    // pop_out came first, so the hand-off ended the turn and the seek never ran: it has a name and no tool_call line.
    const wrongOrderSample = sampleFromHarnessRecord(
      popOutCase,
      0,
      replay(popOutCase, [[turn1Line("pop_out,seek_to_moment"), 400], [toolCallLine("call-1", "pop_out", {}, 0), 402], [finishedLine(""), 430]]).record,
    );
    const lookedItUpFirst = sampleFromHarnessRecord(
      popOutCase,
      0,
      replay(popOutCase, [...findMomentTurn, [turnLine(2, "seek_to_time,pop_out"), 800], [toolCallLine("call-2", "seek_to_time", { seconds: 98 }, 1), 802], [toolCallLine("call-3", "pop_out", {}, 1), 804], [finishedLine(""), 830]]).record,
    );

    assert.equal(droppedThePopOut.outcome, "wrongTool");
    assert.equal(wrongOrderSample.outcome, "wrongTool");
    assert.equal(lookedItUpFirst.outcome, "wrongTool");
    assert.equal(scoreToolCalls(wrongOrderSample.toolCalls.map((toolCall) => toolCall.name), acceptedAnswersOf(popOutCase)), "pass");
  });

  it("passes a lookup that feeds a seek across turns, with the seek's time taken from the scripted lookup, and reports every turn's cost", () => {
    const passedSample = scoreSecondTurn(findLastCase, "seek_to_time", [[toolCallLine("call-2", "seek_to_time", { seconds: 470 }, 1), 802]]);

    assert.equal(passedSample.outcome, "pass");
    assert.deepEqual(passedSample.toolCalls.map((toolCall) => toolCall.name), ["find_moment", "seek_to_time"]);
    assert.equal(passedSample.turnCount, 2);
    // The first turn alone costs less than the command, which adds both turns.
    assert.ok((passedSample.fullCommandCostUSD ?? 0) > (passedSample.costUSD ?? Infinity));
  });

  it("fails a plan that stops early, and a seek whose time is not the scripted one", () => {
    const stoppedAfterTheLookup = sampleFromHarnessRecord(findLastCase, 0, replay(findLastCase, [...findMomentTurn, [finishedLine("I found it"), 500]]).record);
    const seekedToTheBestMatch = scoreSecondTurn(findLastCase, "seek_to_time", [[toolCallLine("call-2", "seek_to_time", { seconds: 305 }, 1), 802]]);
    const neverLookedUp = sampleFromHarnessRecord(findLastCase, 0, replay(findLastCase, [[turn1Line("none"), 400], [finishedLine("it is a shark"), 410]]).record);

    assert.equal(stoppedAfterTheLookup.outcome, "wrongTool");
    assert.equal(seekedToTheBestMatch.outcome, "wrongInput");
    assert.equal(neverLookedUp.outcome, "missedTool");
  });

  it("holds each accepted sequence to its own input, so one seek to 295 and two seeks from 305 both pass and a mix does not", () => {
    const backUpOnce = scoreSecondTurn(twoSequenceCase, "seek_to_time", [[toolCallLine("call-2", "seek_to_time", { seconds: 295 }, 1), 802]]);
    const seekThenBackUp = scoreSecondTurn(twoSequenceCase, "seek_to_time,seek_relative", [
      [toolCallLine("call-2", "seek_to_time", { seconds: 305 }, 1), 802],
      [toolCallLine("call-3", "seek_relative", { seconds: -10 }, 1), 804],
    ]);
    const backedUpTwice = scoreSecondTurn(twoSequenceCase, "seek_to_time,seek_relative", [
      [toolCallLine("call-2", "seek_to_time", { seconds: 295 }, 1), 802],
      [toolCallLine("call-3", "seek_relative", { seconds: -10 }, 1), 804],
    ]);
    const forgotToBackUp = scoreSecondTurn(twoSequenceCase, "seek_to_time", [[toolCallLine("call-2", "seek_to_time", { seconds: 305 }, 1), 802]]);

    assert.equal(backUpOnce.outcome, "pass");
    assert.equal(seekThenBackUp.outcome, "pass");
    assert.equal(backedUpTwice.outcome, "wrongInput");
    assert.equal(forgotToBackUp.outcome, "wrongInput");
  });

  it("takes a seek to a found moment and a relative seek in one reply, and holds the relative seek to -10", () => {
    const backedUp = scoreOneTurn(backUpCase, [["seek_to_moment", { query: "liver" }], ["seek_relative", { seconds: -10 }]]);
    const backedUpTheWrongWay = scoreOneTurn(backUpCase, [["seek_to_moment", { query: "liver" }], ["seek_relative", { seconds: 10 }]]);

    assert.equal(backedUp.outcome, "pass");
    assert.equal(backedUpTheWrongWay.outcome, "wrongInput");
  });

  it("are 10 cases the Worker backend does not run, and the parity cases leave them out", () => {
    const planningCases = evalFile.cases.filter((brainCase) => brainCase.scoreWholeCommand === true);
    const planningSample = sample({ backend: "harness", suite: "planning" });
    const parityCaseSample = sample({ backend: "harness" });
    const split = splitBySuite([parityCaseSample, planningSample]);

    assert.equal(planningCases.length, 10);
    assert.deepEqual(split.parityCaseSamples, [parityCaseSample]);
    assert.deepEqual(split.planningSamples, [planningSample]);
    validateBrainEvals(evalFile, toolCatalog);
  });

  it("cover a lookup that feeds a seek, a hand-off that must come last, and actions in a fixed order", () => {
    const planningCases = evalFile.cases.filter((brainCase) => brainCase.scoreWholeCommand === true);

    assert.ok(planningCases.some((brainCase) => acceptedAnswersOf(brainCase).every((calls) => calls[0] === "find_moment" && calls.includes("seek_to_time"))), "a lookup the router must read, such as the last mention, stays on find_moment");
    assert.ok(planningCases.some((brainCase) => acceptedAnswersOf(brainCase).length === 1 && acceptedAnswersOf(brainCase)[0].join() === "seek_to_moment,pop_out"));
    assert.ok(planningCases.some((brainCase) => acceptedAnswersOf(brainCase).length === 1 && acceptedAnswersOf(brainCase)[0].join() === "seek_relative,pop_out"));
    assert.ok(planningCases.some((brainCase) => acceptedAnswersOf(brainCase).length === 1 && acceptedAnswersOf(brainCase)[0].join() === "rotate_model,zoom_to_part"));
  });

  it("fails a pop-out the harness still sent to the app after a failed seek, and passes one it skipped", () => {
    const failedSeekCase = fixtureCase("planning-seek-fails-then-pop-out");
    // Both calls are named in the turn line, since the model made both. Only a call the app received has a tool_call line.
    const harnessSkippedThePopOut = sampleFromHarnessRecord(
      failedSeekCase,
      0,
      replay(failedSeekCase, [[turn1Line("seek_to_moment,pop_out"), 400], [toolCallLine("call-1", "seek_to_moment", { query: "gills" }, 0), 402], [finishedLine("I could not find that."), 430]]).record,
    );
    const harnessRanThePopOutAnyway = sampleFromHarnessRecord(
      failedSeekCase,
      0,
      replay(failedSeekCase, [[turn1Line("seek_to_moment,pop_out"), 400], [toolCallLine("call-1", "seek_to_moment", { query: "gills" }, 0), 402], [toolCallLine("call-2", "pop_out", {}, 0), 404], [finishedLine(""), 430]]).record,
    );

    assert.equal(harnessSkippedThePopOut.outcome, "pass");
    assert.equal(harnessRanThePopOutAnyway.outcome, "wrongTool");
    assert.deepEqual(failedSeekCase.mustNotReachTheApp, ["pop_out"]);
  });

  it("covers a particular mention, which stays on the lookup", () => {
    const secondMentionCase = fixtureCase("planning-find-second-mention");
    const seekedToTheSecondMention = scoreSecondTurn(secondMentionCase, "seek_to_time", [[toolCallLine("call-2", "seek_to_time", { seconds: 402 }, 1), 802]]);
    const seekedToTheLastMention = scoreSecondTurn(secondMentionCase, "seek_to_time", [[toolCallLine("call-2", "seek_to_time", { seconds: 470 }, 1), 802]]);

    assert.equal(seekedToTheSecondMention.outcome, "pass");
    assert.equal(seekedToTheLastMention.outcome, "wrongInput");
  });

  it("are rejected when mustNotReachTheApp is on a case not scored on the whole command, or names a tool the context does not offer", () => {
    const withCase = (brainCase: BrainCase): BrainEvalFile => ({ ...evalFile, cases: [...evalFile.cases, brainCase] });
    const validCase: BrainCase = { id: "new-planning-case", context: "video", say: "x", why: "x", scoreWholeCommand: true, accept: [["seek_relative", "pop_out"]], mustNotReachTheApp: ["pop_out"] };

    validateBrainEvals(withCase(validCase), toolCatalog);
    assert.throws(() => validateBrainEvals(withCase({ ...validCase, scoreWholeCommand: undefined }), toolCatalog), /only a case scored on the whole command/);
    assert.throws(() => validateBrainEvals(withCase({ ...validCase, mustNotReachTheApp: ["not_a_tool"] }), toolCatalog), /does not offer/);
  });

  it("are rejected when a sequence has its own input outside a planning case, calls find_moment with no scripted result, or checks a tool it does not call", () => {
    const withCase = (brainCase: BrainCase): BrainEvalFile => ({ ...evalFile, cases: [...evalFile.cases, brainCase] });
    const validCase: BrainCase = { id: "new-planning-case", context: "video", say: "x", why: "x", scoreWholeCommand: true, accept: [["seek_relative", "pop_out"]] };

    validateBrainEvals(withCase(validCase), toolCatalog);
    assert.throws(
      () => validateBrainEvals(withCase({ ...validCase, scoreWholeCommand: undefined, accept: [{ calls: ["seek_relative"], input: { seek_relative: { seconds: -30 } } }] }), toolCatalog),
      /not scored on the whole command/,
    );
    assert.throws(() => validateBrainEvals(withCase({ ...validCase, accept: [["find_moment", "seek_to_time"]] }), toolCatalog), /must script the lookup's result/);
    assert.throws(
      () => validateBrainEvals(withCase({ ...validCase, accept: [{ calls: ["seek_relative", "pop_out"], input: { pause_video: { seconds: 1 } } }] }), toolCatalog),
      /does not call/,
    );
    assert.throws(() => validateBrainEvals(withCase({ ...validCase, accept: ["none"] }), toolCatalog), /at least one call/);
  });
});

describe("the approval cases on the harness backend", () => {
  const fakeHarness = { command: process.execPath, args: [join(benchDirectory, "fixtures", "fake-brain-harness.ts")] };
  const approvalCases = evalFile.cases.filter((brainCase) => waitingApprovalCapabilityOf(brainCase, evalFile) !== undefined);
  const settled = (approved: boolean, scope: "once" | "always") => ({ approved, scope });

  it("covers the seven cases of the approvalWaiting context, and every one has a score path", () => {
    assert.equal(approvalCases.filter((brainCase) => brainCase.context === "approvalWaiting").length, 7);
    // The injection case of the session suite also runs with a waiting request, so it is scored the same way.
    assert.ok(approvalCases.length >= 7);
    for (const brainCase of approvalCases) {
      const wantsAnAnswer = acceptedAnswersOf(brainCase).some((answer) => answer.includes("answer_approval"));
      const calledTheTool = [{ name: "answer_approval", input: {}, inputIsUnknown: true }];
      const expected = brainCase.input?.answer_approval;
      assert.equal(
        scoreApprovalCase(calledTheTool, expected === undefined ? null : settled(expected.approved === true, expected.always === true ? "always" : "once"), brainCase),
        wantsAnAnswer ? "pass" : "wrongTool",
        brainCase.id,
      );
    }
  });

  it("sends the request's ID as waiting and seen at the press with no approvalWaiting in the scene state, and null IDs when nothing waits", () => {
    const yes = voiceCommandMessageFor(fixtureCase("approval-yes"), evalFile, toolCatalog, "cmd-1");
    assert.equal(yes.approvalIDWaitingAtPress, approvalIDFor("cmd-1"));
    assert.equal(yes.approvalIDSeenAtPress, approvalIDFor("cmd-1"));
    assert.equal(voiceCommandMessageFor(fixtureCase("video-seek-back"), evalFile, toolCatalog, "cmd-1").approvalIDWaitingAtPress, null);
    assert.ok(!("approvalWaiting" in yes.sceneState), "the app sends no approvalWaiting on the harness path");
    assert.equal(voiceCommandMessageFor(fixtureCase("video-seek-back"), evalFile, toolCatalog, "cmd-1").approvalIDSeenAtPress, null);
    // The Worker backend still sends the word the old path sends.
    assert.equal(sceneStateOf(fixtureCase("approval-yes"), evalFile).approvalWaiting, "sends");
  });

  it("seeds the waiting request after the reset, with the kind of action the context names", () => {
    assert.deepEqual(sessionLinesFor(fixtureCase("approval-yes"), evalFile, "cmd-1"), [
      { type: "reset_session" },
      { type: "seed_approval_request", approvalID: approvalIDFor("cmd-1"), capability: "sends" },
    ]);
    assert.deepEqual(sessionLinesFor(fixtureCase("video-seek-back"), evalFile, "cmd-1"), [{ type: "reset_session" }]);
  });

  it("passes a case that expects an answer only when the gate settled the expected one", () => {
    const calledTheTool = [{ name: "answer_approval", input: {}, inputIsUnknown: true }];
    const yes = fixtureCase("approval-yes");
    const always = fixtureCase("approval-always");
    const no = fixtureCase("approval-no");

    assert.equal(scoreApprovalCase(calledTheTool, settled(true, "once"), yes), "pass");
    assert.equal(scoreApprovalCase(calledTheTool, settled(true, "always"), yes), "wrongInput", "an always the case did not expect");
    assert.equal(scoreApprovalCase(calledTheTool, settled(false, "once"), yes), "wrongInput");
    assert.equal(scoreApprovalCase(calledTheTool, null, yes), "wrongInput", "the tool was called and the harness settled nothing");
    assert.equal(scoreApprovalCase(calledTheTool, settled(true, "always"), always), "pass");
    assert.equal(scoreApprovalCase(calledTheTool, settled(true, "once"), always), "wrongInput");
    assert.equal(scoreApprovalCase(calledTheTool, settled(false, "once"), no), "pass");
    assert.equal(scoreApprovalCase([], null, yes), "missedTool");
  });

  it("passes an unrelated command only with its own tool call and no settlement", () => {
    const pause = fixtureCase("approval-unrelated-pause");
    const calledPause = [{ name: "pause_video", input: {} }];

    assert.equal(scoreApprovalCase(calledPause, null, pause), "pass");
    assert.equal(scoreApprovalCase(calledPause, settled(true, "once"), pause), "wrongInput", "a request settled by an unrelated command");
    assert.equal(scoreApprovalCase([{ name: "answer_approval", input: {}, inputIsUnknown: true }], settled(true, "once"), pause), "wrongTool");
    assert.equal(scoreApprovalCase([{ name: "play_video", input: {} }], null, pause), "wrongTool");
  });

  it("reads the line and the messages harness/voiceapproval.go and protocol.go write", () => {
    const voiceApprovalSource = readFileSync(join(benchDirectory, "..", "harness", "voiceapproval.go"), "utf8");
    const protocolSource = readFileSync(join(benchDirectory, "..", "harness", "protocol.go"), "utf8");
    // The log line is "Brain: approval <id> given|declined (<scope>)", which the recorder's pattern reads.
    assert.ok(voiceApprovalSource.includes('"Brain: approval %s %s (%s)"'));
    assert.ok(voiceApprovalSource.includes('logVerdict, answerWord = "given", "allowed"') && voiceApprovalSource.includes('logVerdict, answerWord := "declined", "declined"'));
    assert.ok(protocolSource.includes('Type: "approval_settled"'));
    assert.ok(protocolSource.includes('case "seed_approval_request":'));
  });

  it("reads the settlement from approval_settled, or from the Brain: approval log line, for the seeded request only", () => {
    const yes = fixtureCase("approval-yes");
    const fromTheLine = new HarnessCommandRecorder(yes, "cmd-1", approvalIDFor("cmd-1"));
    fromTheLine.receive({ type: "approval_settled", approvalID: approvalIDFor("cmd-1"), approved: true, scope: "always" }, 10);
    assert.deepEqual(fromTheLine.record.approvalSettlement, settled(true, "always"));

    const fromTheLog = new HarnessCommandRecorder(yes, "cmd-1", approvalIDFor("cmd-1"));
    fromTheLog.receive({ type: "log", message: `Brain: approval ${approvalIDFor("cmd-1")} declined (once)` }, 10);
    assert.deepEqual(fromTheLog.record.approvalSettlement, settled(false, "once"));

    const forAnotherRequest = new HarnessCommandRecorder(yes, "cmd-1", approvalIDFor("cmd-1"));
    forAnotherRequest.receive({ type: "approval_settled", approvalID: "approval-someone-else", approved: true, scope: "once" }, 10);
    forAnotherRequest.receive({ type: "log", message: "Brain: approval approval-someone-else given (once)" }, 11);
    assert.equal(forAnotherRequest.record.approvalSettlement, null);
  });

  it("scores a command end to end from the harness's approval_settled line, and scores the wrong settlement as a wrong input", async () => {
    const harnessBrain = await startHarnessBrain(fakeHarness, 1, "s3cret");
    try {
      const yes = { ...fixtureCase("approval-yes"), say: "approve it" };
      const settledRecord = await runCaseOnTheHarness(harnessBrain, yes, evalFile, toolCatalog);
      assert.deepEqual(settledRecord.approvalSettlement, settled(true, "once"));
      assert.equal(sampleFromHarnessRecord(yes, 0, settledRecord).outcome, "pass");

      const no = { ...fixtureCase("approval-no"), say: "deny it" };
      assert.equal(sampleFromHarnessRecord(no, 0, await runCaseOnTheHarness(harnessBrain, no, evalFile, toolCatalog)).outcome, "pass");
      // The model asked for the wrong answer: the case wants a yes, and the harness settled a no.
      assert.equal(sampleFromHarnessRecord({ ...yes, say: "deny it" }, 0, await runCaseOnTheHarness(harnessBrain, { ...yes, say: "deny it" }, evalFile, toolCatalog)).outcome, "wrongInput");
    } finally {
      harnessBrain.stop();
    }
  });
});
