import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import { benchCases, type AppProfile, type BenchCase } from "./bench.ts";

const benchDirectory = dirname(fileURLToPath(import.meta.url));

const appProfile: AppProfile = {
  chatModel: "claude-sonnet-5-5",
  chatEffort: "low",
  chatSystemPromptCached: true,
  chatSystemPrompt: "you are clicky",
  ttsModel: "eleven_v4_turbo",
  ttsOutputFormat: "pcm_24000",
  ttsFirstBufferBytes: 9600,
};

function benchCase(caseId: string): BenchCase {
  const foundCase = benchCases.find((candidate) => candidate.id === caseId);
  assert.ok(foundCase, `no case ${caseId}`);
  return foundCase;
}

/** What /voice-command's Worker returns: text and tool_use blocks. */
function voiceReply(...toolCalls: Array<[string, Record<string, unknown>]>): string {
  return JSON.stringify({
    content: [{ type: "text", text: "ok" }, ...toolCalls.map(([name, input], callIndex) => ({ type: "tool_use", id: `t${callIndex}`, name, input }))],
    stopReason: "tool_use",
  });
}

const check = (caseId: string, replyText: string) => benchCase(caseId).checkReply(replyText, "application/json", replyText.length);

describe("benchCases", () => {
  it("has one case per id", () => {
    const caseIds = benchCases.map((candidate) => candidate.id);

    assert.equal(new Set(caseIds).size, caseIds.length);
  });

  it("builds a JSON request body for every case that does not need the app's profile, so a missing fixture shows before a run", () => {
    for (const candidate of benchCases.filter((benchCaseToBuild) => benchCaseToBuild.route !== "/chat")) {
      assert.doesNotThrow(() => JSON.stringify(candidate.requestBody(appProfile)), `${candidate.id} request body`);
    }
  });

  it("names every case the morning runbook's --only lists run, so a renamed case cannot leave the runbook pointing at nothing", () => {
    const readmeText = readFileSync(join(benchDirectory, "README.md"), "utf8");
    const onlyLists = [...readmeText.matchAll(/--only ([a-z0-9,-]+)/g)].map((onlyMatch) => onlyMatch[1].split(","));

    assert.ok(onlyLists.length >= 7, "the runbook lists a run for each of the 7 routes");
    for (const caseId of onlyLists.flat()) {
      assert.ok(benchCases.some((candidate) => candidate.id === caseId), `README names the case ${caseId}, which does not exist`);
    }
  });
});

describe("the /voice-command cases", () => {
  it("swap the learner's words into the app's own body and keep its tools and scene state", () => {
    const zoomBody = benchCase("voice-command-zoom").requestBody(appProfile) as { messages: [{ content: string }]; tools: Array<{ name: string }> };
    const originalBody = JSON.parse(readFileSync(join(benchDirectory, "fixtures", "voice-command.json"), "utf8"));

    assert.ok(zoomBody.messages[0].content.endsWith('Learner said: "zoom in a little"'));
    assert.equal(zoomBody.messages[0].content.split("Learner said:")[0], originalBody.messages[0].content.split("Learner said:")[0]);
    assert.deepEqual(zoomBody.tools, originalBody.tools);
  });

  it("offer the video tools over a YouTube video for the seek case", () => {
    const seekBody = benchCase("voice-command-seek").requestBody(appProfile) as { tools: Array<{ name: string }> };

    assert.ok(["seek_relative", "seek_to_time", "find_moment"].every((toolName) => seekBody.tools.some((tool) => tool.name === toolName)));
  });

  it("pass the seek case for going back 30 seconds either way, and fail a wrong direction, size, or a missing confirmation", () => {
    assert.equal(check("voice-command-seek", voiceReply(["seek_relative", { seconds: -30, confirmation: "back 30 seconds" }])).passed, true);
    assert.equal(check("voice-command-seek", voiceReply(["seek_to_time", { seconds: 94, confirmation: "back 30 seconds" }])).passed, true);
    assert.equal(check("voice-command-seek", voiceReply(["seek_relative", { seconds: 30, confirmation: "ahead" }])).passed, false);
    assert.equal(check("voice-command-seek", voiceReply(["seek_relative", { seconds: -10, confirmation: "back" }])).passed, false);
    assert.equal(check("voice-command-seek", voiceReply(["seek_relative", { seconds: -30 }])).passed, false);
    assert.equal(check("voice-command-seek", voiceReply(["seek_relative", { seconds: -30, confirmation: "back" }], ["pause_video", { confirmation: "paused" }])).passed, false);
  });

  it("pass the zoom case for one zoom in, and fail a zoom out, a zoom to a part, or no call", () => {
    assert.equal(check("voice-command-zoom", voiceReply(["zoom", { factor: 1.3, confirmation: "closer" }])).passed, true);
    assert.equal(check("voice-command-zoom", voiceReply(["zoom", { factor: 0.7, confirmation: "farther" }])).passed, false);
    assert.equal(check("voice-command-zoom", voiceReply(["zoom_to_part", { label: "engine", confirmation: "closer" }])).passed, false);
    assert.equal(check("voice-command-zoom", voiceReply()).passed, false);
  });

  it("pass the explain case for explain_part on the tail, in any letter case, and fail another part", () => {
    assert.equal(check("voice-command-explain", voiceReply(["explain_part", { label: "Tail", confirmation: "the tail" }])).passed, true);
    assert.equal(check("voice-command-explain", voiceReply(["explain_part", { label: "wing", confirmation: "the wing" }])).passed, false);
  });

  it("pass the no-tool case only when the reply holds no tool call", () => {
    assert.equal(check("voice-command-no-tool", voiceReply()).passed, true);
    assert.equal(check("voice-command-no-tool", voiceReply(["answer_with_screen", { confirmation: "looking" }])).passed, false);
  });
});

describe("the new quality checks", () => {
  it("passes the chart frame only when the reply finds no subject", () => {
    assert.equal(check("frame-parts-chart", JSON.stringify({ subjectFound: false })).passed, true);
    assert.equal(check("frame-parts-chart", JSON.stringify({ subjectFound: true, parts: [{}, {}, {}] })).passed, false);
    assert.equal(check("frame-parts-chart", "not json").passed, false);
  });

  it("passes the heart as a non-landmark only when isFamousPlace is false", () => {
    assert.equal(check("landmark-not-a-place", JSON.stringify({ isFamousPlace: false })).passed, true);
    assert.equal(check("landmark-not-a-place", JSON.stringify({ isFamousPlace: true, name: "Eiffel Tower" })).passed, false);
  });

  it("grades the four verdicts the judge added, and fails a hint that names the part", () => {
    assert.equal(check("judge-hint", JSON.stringify({ verdict: "wants_hint", spokenReply: "Think about the chamber that sends blood to the body." })).passed, true);
    assert.equal(check("judge-hint", JSON.stringify({ verdict: "wants_hint", spokenReply: "It is the left ventricle." })).passed, false);
    assert.equal(check("judge-skip", JSON.stringify({ verdict: "skip_question", spokenReply: "" })).passed, true);
    assert.equal(check("judge-repeat", JSON.stringify({ verdict: "repeat_question", spokenReply: "" })).passed, true);
    assert.equal(check("judge-scene-command", JSON.stringify({ verdict: "scene_command", spokenReply: "" })).passed, true);
    assert.equal(check("judge-scene-command", JSON.stringify({ verdict: "wrong", spokenReply: "No." })).passed, false);
  });
});
