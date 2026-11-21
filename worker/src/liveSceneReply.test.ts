import { describe, expect, it } from "vitest";
import {
  checkLiveSceneKernelReply,
  checkLiveSceneModelReply,
  liveSceneFormatSchema,
  liveSceneRequestKindSchema,
  sceneKernelPage,
} from "./liveSceneReply";

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
  getState() { return { readouts: [] }; },
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
    ["readouts", "readouts: []"],
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

  it("does not count run as a word inside another name or a comment", () => {
    const pageWithOnlyOtherRuns = simulationPage
      .replace("run() { return Promise.resolve(); },", "runner: 1,")
      .replace("</body>", "<!-- the app drives the run --></body>");

    const checkedReply = checkLiveSceneModelReply(liveSceneModelReply(pageWithOnlyOtherRuns), "simulation");

    expect(checkedReply).toMatchObject({ accepted: false, reason: "The simulation page is missing run" });
  });

  it("rejects a simulation page that draws its own button, because the app draws the only panel", () => {
    const pageWithItsOwnButton = simulationPage.replace("</body>", '<button id="go">Run</button></body>');

    const checkedReply = checkLiveSceneModelReply(liveSceneModelReply(pageWithItsOwnButton), "simulation");

    expect(checkedReply).toMatchObject({ accepted: false, reason: expect.stringContaining("<button") });
  });

  it.each([
    ['document.createElement("input")', "input"],
    ["document.createElement('button')", "button"],
    ['document.createElement( "select" )', "select"],
    ["document.createElement(`textarea`)", "textarea"],
    ['document.createElement("button", { is: "fancy-button" })', "button"],
    ['document.createElementNS("http://www.w3.org/1999/xhtml", "input")', "input"],
  ])("rejects a simulation page that draws a control with %s", (createElementCall, controlElementName) => {
    const pageWithAScriptedControl = simulationPage.replace("</body>", `<script>${createElementCall};</script></body>`);

    const checkedReply = checkLiveSceneModelReply(liveSceneModelReply(pageWithAScriptedControl), "simulation");

    expect(checkedReply).toMatchObject({
      accepted: false,
      reason: expect.stringContaining(`createElement("${controlElementName}")`),
    });
  });

  it("accepts a simulation page that creates an element that is not a control", () => {
    const pageWithAScriptedLabel = simulationPage.replace("</body>", '<script>document.createElement("div");</script></body>');

    expect(checkLiveSceneModelReply(liveSceneModelReply(pageWithAScriptedLabel), "simulation").accepted).toBe(true);
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

const kernelBuildCode = `function build(kit) {
  const valve = new kit.THREE.Group();
  kit.mesh(new kit.THREE.TorusGeometry(0.02, 0.004), kit.material(0xd5bfa4), valve);
  kit.part("Heart", valve);
  return { insideView: true };
}`;

const kernelSimulationCode = `function build(kit) {
  kit.field({ size: 40 });
  const ball = kit.part("Ball", kit.mesh(new kit.THREE.SphereGeometry(0.2), kit.material(0xf88b43)));
  return {
    controls: [{ name: "angle", label: "Launch angle", min: 15, max: 75, step: 1, value: 30, unit: "degrees" }],
    setup(values) { ball.position.set(0, 0.2, 0); },
    simulate(values) { return { seconds: 2, readouts: [{ label: "Landing distance", value: values.angle, unit: "m" }], show(t) {} }; },
  };
}`;

function kernelModelReply(buildCode: string, quiz: object = liveSceneQuiz): string {
  return "```js\n" + buildCode + "\n```\n```json\n" + JSON.stringify(quiz) + "\n```";
}

describe("kernel reply", () => {
  it("wraps the build function into a page that imports the bundled kernel and starts it", () => {
    const checkedReply = checkLiveSceneKernelReply(kernelModelReply(kernelBuildCode), "model");

    expect(checkedReply.accepted).toBe(true);
    if (!checkedReply.accepted) return;
    expect(checkedReply.quiz).toEqual(liveSceneQuiz);
    expect(checkedReply.html).toContain('<script type="importmap">{ "imports": { "three": "clicky-asset://three/three.module.js" } }</script>');
    expect(checkedReply.html).toContain('import { startScene } from "clicky-asset://three/scene-kernel.js";');
    expect(checkedReply.html).toContain(kernelBuildCode);
    expect(checkedReply.html).toContain('startScene({ kind: "model", answerLabel: "Heart", build });');
  });

  it("writes the answer label with every < escaped, so no label can close the script", () => {
    const page = sceneKernelPage("model", "</script><script>alert(1)</script>", kernelBuildCode);

    expect(page).not.toContain("</script><script>alert(1)");
    expect(page).toContain('answerLabel: "\\u003c/script>\\u003cscript>alert(1)\\u003c/script>"');
  });

  it.each([
    ["has no build function", kernelBuildCode.replace("function build(kit)", "function makeScene(kit)"), "The code must declare function build(kit)"],
    ["imports a module", 'import * as THREE from "three";\n' + kernelBuildCode, "The code must not import or export anything"],
    ["imports a module at run time", kernelBuildCode.replace("return {", 'import("x");\n  return {'), "The code must not import or export anything"],
    ["exports the build function", "export " + kernelBuildCode, "The code must not import or export anything"],
    ["touches window.liveScene", kernelBuildCode.replace("return {", "window.liveScene = {};\n  return {"), "The code must not touch window.liveScene, which the kernel defines"],
    ["closes the script", kernelBuildCode.replace("return {", 'const tag = "</script>";\n  return {'), "The code must not contain a closing script tag"],
    ["reaches a URL", kernelBuildCode.replace("return {", 'fetch("https://example.com");\n  return {'), "The code contains a URL other than the SVG namespace"],
    ["never registers the answer part", kernelBuildCode.replace('"Heart"', '"Valve"'), "No part is registered with the answer label Heart"],
  ])("rejects code that %s, so the retry runs", (_description, buildCode, reason) => {
    expect(checkLiveSceneKernelReply(kernelModelReply(buildCode), "model")).toEqual({ accepted: false, reason });
  });

  it("rejects code that declares a name twice, which stops a module before it draws", () => {
    const codeWithATwiceDeclaredName = kernelBuildCode + "\nfunction stepRun() {}\nfunction stepRun() {}";

    expect(checkLiveSceneKernelReply(kernelModelReply(codeWithATwiceDeclaredName), "model")).toMatchObject({
      accepted: false,
      reason: expect.stringContaining("The code does not parse"),
    });
  });

  it("rejects a reply with no js block, or with the json block first", () => {
    expect(checkLiveSceneKernelReply("```json\n" + JSON.stringify(liveSceneQuiz) + "\n```", "model").accepted).toBe(false);
    expect(checkLiveSceneKernelReply("```json\n" + JSON.stringify(liveSceneQuiz) + "\n```\n```js\n" + kernelBuildCode + "\n```", "model").accepted).toBe(false);
  });

  it("accepts a simulation that returns controls, setup, simulate, and readouts in a lab or a field", () => {
    const checkedReply = checkLiveSceneKernelReply(kernelModelReply(kernelSimulationCode, { ...liveSceneQuiz, answerLabel: "Launch angle" }), "simulation");

    expect(checkedReply.accepted).toBe(true);
    if (!checkedReply.accepted) return;
    expect(checkedReply.html).toContain('startScene({ kind: "simulation", answerLabel: "Launch angle", build });');
  });

  it.each([
    ["controls", "controls: [{", "somethingElse: [{"],
    ["setup", "setup(values)", "prepare(values)"],
    ["simulate", "simulate(values)", "compute(values)"],
    ["readouts", "readouts: [", "values: ["],
    ["kit.lab or kit.field", "kit.field({ size: 40 });", ""],
  ])("rejects a simulation missing %s", (missingName, definition, replacement) => {
    const codeMissingTheName = kernelSimulationCode.replace(definition, replacement);
    expect(codeMissingTheName).not.toBe(kernelSimulationCode);

    expect(checkLiveSceneKernelReply(kernelModelReply(codeMissingTheName), "simulation")).toEqual({
      accepted: false,
      reason: `The simulation code is missing ${missingName}`,
    });
  });

  it("rejects a simulation that draws its own control, because the app draws the only panel", () => {
    const codeWithAButton = kernelSimulationCode.replace("return {", 'document.createElement("button");\n  return {');

    expect(checkLiveSceneKernelReply(kernelModelReply(codeWithAButton), "simulation")).toMatchObject({
      accepted: false,
      reason: expect.stringContaining('createElement("button")'),
    });
  });

  it("does not ask a simulation to register its answer label, which names a control", () => {
    expect(checkLiveSceneKernelReply(kernelModelReply(kernelSimulationCode, { ...liveSceneQuiz, answerLabel: "Speed" }), "simulation").accepted).toBe(true);
  });
});

describe("live scene format", () => {
  it("accepts page and kernel and defaults to page", () => {
    expect(liveSceneFormatSchema.parse("kernel")).toBe("kernel");
    expect(liveSceneFormatSchema.parse(undefined)).toBe("page");
    expect(liveSceneFormatSchema.safeParse("recipe").success).toBe(false);
  });
});
