import { describe, expect, it } from "vitest";
import { checkLiveSceneModelReply, liveSceneRequestKindSchema } from "./liveSceneReply";

const liveSceneQuiz = {
  question: "Here we are, inside the heart! What is this, and what does it do?",
  answerLabel: "Heart",
  functionWords: ["pump", "blood"],
  explanation: "That's the heart, and it pumps blood through the body.",
};

const liveScenePage = `<!DOCTYPE html>
<html>
<body>
<svg xmlns="http://www.w3.org/2000/svg"></svg>
<script type="importmap">
{ "imports": { "three": "clicky-asset://three/three.module.js" } }
</script>
<script type="module">
window.liveScene = {
  reveal() {},
  zoomBy(amount) {},
  focusPart(labelText) { return false; }
};
window.webkit?.messageHandlers?.liveSceneEvent?.postMessage("tourFinished");
</script>
</body>
</html>`;

function liveSceneModelReply(html: string): string {
  return "```html\n" + html + "\n```\n```json\n" + JSON.stringify(liveSceneQuiz) + "\n```";
}

describe("live scene reply", () => {
  it("accepts a page and a quiz", () => {
    const checkedReply = checkLiveSceneModelReply(liveSceneModelReply(liveScenePage));

    expect(checkedReply.accepted).toBe(true);
    if (checkedReply.accepted) {
      expect(checkedReply.quiz.answerLabel).toBe("Heart");
      expect(checkedReply.html).toContain("clicky-asset://three/three.module.js");
    }
  });

  it("rejects a page whose module script does not parse", () => {
    const pageWithATypo = liveScenePage.replace("zoomBy(amount) {},", "zoomBy(amount) { orbit(normal alFix) },");

    const checkedReply = checkLiveSceneModelReply(liveSceneModelReply(pageWithATypo));

    expect(checkedReply).toMatchObject({ accepted: false, reason: expect.stringContaining("does not parse") });
  });

  it("rejects a page that reaches an external URL", () => {
    const pageWithAnExternalURL = liveScenePage.replace(
      "</body>",
      "<!-- https://cdn.example.com/three.module.js --></body>",
    );

    const checkedReply = checkLiveSceneModelReply(liveSceneModelReply(pageWithAnExternalURL));

    expect(checkedReply.accepted).toBe(false);
  });

  it("rejects a page that uses WebRTC in any letter case", () => {
    const pageUsingWebRTC = liveScenePage.replace(
      "</body>",
      "<script>new RTCPeerConnection();</script></body>",
    );

    const checkedReply = checkLiveSceneModelReply(liveSceneModelReply(pageUsingWebRTC));

    expect(checkedReply.accepted).toBe(false);
  });

  it("names every quiz problem on one line, so the Worker log keeps the whole reason", () => {
    const replyWithABrokenQuiz =
      "```html\n" + liveScenePage + "\n```\n```json\n" + JSON.stringify({ ...liveSceneQuiz, answerLabel: "", functionWords: "pump" }) + "\n```";
    const checkedReply = checkLiveSceneModelReply(replyWithABrokenQuiz);
    expect(checkedReply.accepted).toBe(false);
    if (checkedReply.accepted) return;
    expect(checkedReply.reason).not.toContain("\n");
    expect(checkedReply.reason).toContain("answerLabel");
    expect(checkedReply.reason).toContain("functionWords");
  });

  it("rejects a page missing focusPart", () => {
    const pageMissingFocusPart = liveScenePage.replace(
      "focusPart(labelText) { return false; }",
      "lookAtPart(labelText) { return false; }",
    );

    const checkedReply = checkLiveSceneModelReply(liveSceneModelReply(pageMissingFocusPart));

    expect(checkedReply.accepted).toBe(false);
  });
});

const simulationPage = liveScenePage.replace(
  "reveal() {},",
  `reveal() {},
  controls: [{ name: "angle", label: "Launch angle", min: 5, max: 85, step: 1, value: 45, unit: "degrees" }],
  setControl(name, value) { return name === "angle"; },
  run() { return Promise.resolve(); },
  reset() {},`,
);

describe("simulation reply", () => {
  it("accepts a simulation page with controls, setControl, and run", () => {
    const checkedReply = checkLiveSceneModelReply(liveSceneModelReply(simulationPage), "simulation");

    expect(checkedReply.accepted).toBe(true);
  });

  it.each([
    ["controls", "controls: [{"],
    ["setControl", "setControl(name, value)"],
    ["run", "run()"],
  ])("rejects a simulation page that lacks %s, so the retry runs", (missingName, definition) => {
    const replacement = definition.replace(missingName, "somethingElse");
    const pageMissingTheName = simulationPage.replace(definition, replacement);
    expect(pageMissingTheName).not.toBe(simulationPage);

    const checkedReply = checkLiveSceneModelReply(liveSceneModelReply(pageMissingTheName), "simulation");

    expect(checkedReply).toMatchObject({ accepted: false, reason: `The simulation page is missing ${missingName}` });
  });

  it("does not count a name that only appears in a comment", () => {
    const pageWithControlsOnlyInAComment = simulationPage
      .replace("controls: [{", "somethingElse: [{")
      .replace("</body>", "<!-- controls are drawn by the app --></body>");

    const checkedReply = checkLiveSceneModelReply(liveSceneModelReply(pageWithControlsOnlyInAComment), "simulation");

    expect(checkedReply).toMatchObject({ accepted: false, reason: "The simulation page is missing controls" });
  });

  it("rejects a simulation page that draws its own button, because the app draws the only panel", () => {
    const pageWithItsOwnButton = simulationPage.replace("</body>", '<button id="go">Run</button></body>');

    const checkedReply = checkLiveSceneModelReply(liveSceneModelReply(pageWithItsOwnButton), "simulation");

    expect(checkedReply).toMatchObject({ accepted: false, reason: expect.stringContaining("<button") });
  });

  it("still accepts a model page that has no controls", () => {
    expect(checkLiveSceneModelReply(liveSceneModelReply(liveScenePage), "model").accepted).toBe(true);
    expect(checkLiveSceneModelReply(liveSceneModelReply(liveScenePage)).accepted).toBe(true);
  });

  it("rejects a plain model page when a simulation was asked for", () => {
    expect(checkLiveSceneModelReply(liveSceneModelReply(liveScenePage), "simulation").accepted).toBe(false);
  });
});

describe("live scene request kind", () => {
  it("accepts both kinds and defaults to model", () => {
    expect(liveSceneRequestKindSchema.parse("model")).toBe("model");
    expect(liveSceneRequestKindSchema.parse("simulation")).toBe("simulation");
    expect(liveSceneRequestKindSchema.parse(undefined)).toBe("model");
  });

  it("rejects a kind it does not know", () => {
    expect(liveSceneRequestKindSchema.safeParse("quiz").success).toBe(false);
  });
});
