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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
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

describe("the /theme-ideas cases", () => {
  const idea = (overrides: Record<string, unknown> = {}) => ({
    name: "Moonlit",
    accent: "#7DD3FC",
    contrast: "#1E1B4B",
    cursor: { kind: "shapes", shapes: [{ d: "M12 2 L22 22 L2 22 Z", fill: "#7DD3FC", stroke: null, strokeWidth: 0 }], picture: null },
    agents: { ring: "perAgent", colors: ["#7DD3FC", "#C4B5FD", "#FDE68A"], faces: { kind: "triangle" } },
    ...overrides,
  });
  const themeReply = (...ideas: object[]) => JSON.stringify({ title: "Three ideas", spokenLine: "Here are three.", ideas });

  it("sends the words alone, and the words with the Starry Night frame as a picture", () => {
    const wordsBody = benchCase("theme-ideas-words").requestBody(appProfile);
    const pictureBody = benchCase("theme-ideas-picture").requestBody(appProfile);
    assert.ok(isRecord(wordsBody) && isRecord(pictureBody));
    assert.equal(wordsBody.request, "something cozy for night");
    assert.equal(wordsBody.picture, undefined);
    const picture = pictureBody.picture;
    assert.ok(isRecord(picture) && typeof picture.jpegBase64 === "string");
    assert.ok(picture.jpegBase64.length > 1000);
    assert.deepEqual([picture.width, picture.height], [1280, 720]);
  });

  it("passes the words case for three well-formed ideas that use no picture, and fails a picture that was never sent", () => {
    assert.equal(check("theme-ideas-words", themeReply(idea(), idea(), idea())).passed, true);
    assert.equal(check("theme-ideas-words", themeReply(idea({ agents: { ring: "accent", colors: [], faces: { kind: "picture" } } }), idea(), idea())).passed, false);
    assert.equal(check("theme-ideas-words", themeReply(idea({ cursor: { kind: "picture", shapes: [], picture: null } }), idea(), idea())).passed, false);
  });

  it("fails two ideas, a lowercase color, and an arc", () => {
    assert.equal(check("theme-ideas-words", themeReply(idea(), idea())).passed, false);
    assert.equal(check("theme-ideas-words", themeReply(idea({ accent: "#7dd3fc" }), idea(), idea())).passed, false);
    const arcCursor = { kind: "shapes", shapes: [{ d: "M2 2 A5 5 0 0 1 20 20", fill: "#7DD3FC", stroke: null, strokeWidth: 0 }], picture: null };
    assert.equal(check("theme-ideas-words", themeReply(idea({ cursor: arcCursor }), idea(), idea())).passed, false);
  });

  it("passes the picture case only when at least one idea uses the picture, in a version 2 or a version 1 idea", () => {
    assert.equal(check("theme-ideas-picture", themeReply(idea({ agents: { ring: "accent", colors: [], faces: { kind: "picture" } } }), idea(), idea())).passed, true);
    assert.equal(check("theme-ideas-picture", themeReply(idea({ agents: undefined, agentColors: ["#7DD3FC", "#C4B5FD", "#FDE68A"], usesPicture: true }), idea(), idea())).passed, true);
    assert.equal(check("theme-ideas-words", themeReply(idea({ agents: { ring: "perAgent", colors: ["#7dd3fc"], faces: { kind: "triangle" } } }), idea(), idea())).passed, false);
    assert.equal(check("theme-ideas-picture", themeReply(idea(), idea(), idea())).passed, false);
    assert.equal(check("theme-ideas-picture", "not json").passed, false);
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
