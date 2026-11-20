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
  pageToolDescriptionsIn,
  percentile,
  requestBodyFor,
  scoreBrainCase,
  scoreToolCalls,
  skillInputDescription,
  skillInstructionSentence,
  summarizeByContext,
  summarizeSamples,
  toolCallsIn,
  toolsWithStaleDescriptions,
  validateBrainEvals,
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
    caseId: "case",
    context: "video",
    runIndex: 0,
    httpStatus: 200,
    totalMs: 1000,
    outcome: "pass",
    toolCalls: [],
    spokenText: "",
    usageLines: [],
    costUSD: 0.001,
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
