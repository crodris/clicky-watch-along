import { parse as parseJavaScript } from "acorn";
import { z } from "zod";
import { zodIssuesOnOneLine } from "./anthropic";

export const liveSceneQuizSchema = z.object({
  question: z.string().min(1),
  answerLabel: z.string().min(1),
  functionWords: z.array(z.string()),
  explanation: z.string().min(1),
});

/** A 3D model of the subject, or a simulation of it. The app sends the kind, and a request with none is a model. */
export const liveSceneRequestKindSchema = z.enum(["model", "simulation"]).default("model");

export type LiveSceneRequestKind = z.infer<typeof liveSceneRequestKindSchema>;

export type LiveSceneQuiz = z.infer<typeof liveSceneQuizSchema>;

export type CheckedLiveSceneReply =
  | { accepted: true; html: string; quiz: LiveSceneQuiz }
  | { accepted: false; reason: string };

const pageMarkersTheAppCalls = ["liveScene", "tourFinished", "reveal", "zoomBy", "focusPart"] as const;

// What scene-tools.js reads to draw the panel and run the simulation. Each pattern needs the shape a definition has,
// such as "run(" or "controls:", so a bare mention does not count, though a comment written in that shape still does.
const simulationMarkers = [
  { name: "controls", pattern: /\bcontrols\s*[:=]/ },
  { name: "setControl", pattern: /\bsetControl\s*[(:=]/ },
  { name: "run", pattern: /\brun\s*[(:=]/ },
  // getState() must report readouts, or a run ends with nothing for the panel or Clicky to say.
  { name: "readouts", pattern: /\breadouts\s*[:=]/ },
] as const;

// The app draws the only control panel, so a second one from the page would show twice.
// A page can draw a control as markup or with createElement or createElementNS, so both forms are refused. The patterns
// are lowercase because they run on the lowercased page.
const controlElementNames = ["input", "button", "select", "textarea"] as const;
const controlElementsASimulationMustNotDraw = controlElementNames.flatMap((controlElementName) => [
  { description: `<${controlElementName}`, pattern: new RegExp(`<${controlElementName}`) },
  {
    description: `createElement("${controlElementName}")`,
    pattern: new RegExp(`createelement(?:ns)?\\s*\\([^)]*?["'\`]${controlElementName}["'\`]\\s*[,)]`),
  },
]);

function controlElementDrawnIn(text: string): string | undefined {
  const lowercaseText = text.toLowerCase();
  return controlElementsASimulationMustNotDraw.find((controlElement) => controlElement.pattern.test(lowercaseText))?.description;
}

// The SVG namespace is a URL, and a label leader line may use it. Every other
// http(s) URL is a network request the generated page is not allowed to make.
const svgNamespacePrefix = "www\\.w3\\.org\\/2000\\/svg";

function firstScriptSyntaxError(html: string): string | undefined {
  for (const scriptMatch of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
    const scriptAttributes = scriptMatch[1] ?? "";
    const scriptText = scriptMatch[2] ?? "";
    if (/type\s*=\s*["']importmap["']/i.test(scriptAttributes)) {
      continue;
    }
    const isModuleScript = /type\s*=\s*["']module["']/i.test(scriptAttributes);
    try {
      parseJavaScript(scriptText, { ecmaVersion: "latest", sourceType: isModuleScript ? "module" : "script" });
    } catch (parseError) {
      return parseError instanceof Error ? parseError.message : String(parseError);
    }
  }
  return undefined;
}

export function checkLiveSceneModelReply(modelReply: string, kind: LiveSceneRequestKind = "model"): CheckedLiveSceneReply {
  const htmlFenceStart = modelReply.indexOf("```html");
  const jsonFenceStart = modelReply.indexOf("```json");
  if (htmlFenceStart < 0 || jsonFenceStart < 0 || htmlFenceStart > jsonFenceStart) {
    return { accepted: false, reason: "The reply must be an html block followed by a json block" };
  }

  const htmlBlockMatch = modelReply.match(/```html\s*([\s\S]*?)```/);
  const jsonBlockMatch = modelReply.match(/```json\s*([\s\S]*?)```/);
  const html = htmlBlockMatch?.[1]?.trim();
  const jsonText = jsonBlockMatch?.[1]?.trim();
  if (html === undefined || html.length === 0) {
    return { accepted: false, reason: "The reply had no ```html block" };
  }
  if (jsonText === undefined || jsonText.length === 0) {
    return { accepted: false, reason: "The reply had no ```json block" };
  }

  const missingMarker = pageMarkersTheAppCalls.find((pageMarker) => !html.includes(pageMarker));
  if (missingMarker !== undefined) {
    return { accepted: false, reason: `The page is missing ${missingMarker}` };
  }

  if (kind === "simulation") {
    const missingSimulationMarker = simulationMarkers.find((simulationMarker) => !simulationMarker.pattern.test(html));
    if (missingSimulationMarker !== undefined) {
      return { accepted: false, reason: `The simulation page is missing ${missingSimulationMarker.name}` };
    }
    const drawnControl = controlElementDrawnIn(html);
    if (drawnControl !== undefined) {
      return { accepted: false, reason: `The simulation page draws its own control (${drawnControl}), and the app draws the only panel` };
    }
  }

  // A typo in the generated script stops the page before it draws, and the app would wait
  // for a tour that never ends. About 1 in 10 pages had one on 2026-11-03, so check here and let the retry run.
  const scriptSyntaxError = firstScriptSyntaxError(html);
  if (scriptSyntaxError !== undefined) {
    return { accepted: false, reason: `A page script does not parse: ${scriptSyntaxError}` };
  }

  if (hasADisallowedURL(html)) {
    return { accepted: false, reason: "The page contains a URL other than the SVG namespace" };
  }

  const parsedQuiz = parsedQuizBlock(jsonText);
  if (!parsedQuiz.ok) {
    return { accepted: false, reason: parsedQuiz.reason };
  }

  return { accepted: true, html, quiz: parsedQuiz.quiz };
}

/** Every URL except the SVG namespace is a network request a generated page is not allowed to make. */
function hasADisallowedURL(text: string): boolean {
  // The namespace has to end here. A longer host that only starts with it is still a URL.
  const textWithoutTheSvgNamespace = text.toLowerCase().replace(
    new RegExp(`https?:\\/\\/${svgNamespacePrefix}\\/?(?=$|[^a-z0-9._~-])`, "g"),
    "",
  );
  return ["http://", "https://", "ws://", "wss://", "stun:", "stuns:", "turn:", "turns:", "rtcpeerconnection", "<iframe"].some((urlPrefix) =>
    textWithoutTheSvgNamespace.includes(urlPrefix),
  );
}

function parsedQuizBlock(jsonText: string): { ok: true; quiz: LiveSceneQuiz } | { ok: false; reason: string } {
  let quizJSON: unknown;
  try {
    quizJSON = JSON.parse(jsonText);
  } catch {
    return { ok: false, reason: "The json block did not parse" };
  }
  const parsedQuiz = liveSceneQuizSchema.safeParse(quizJSON);
  return parsedQuiz.success ? { ok: true, quiz: parsedQuiz.data } : { ok: false, reason: zodIssuesOnOneLine(parsedQuiz.error) };
}

/**
 * How the model writes a scene. "page" is a whole self-contained page. "kernel" is a build(kit) function that the Worker
 * wraps into a page importing the app's bundled scene kernel (leanring-buddy/LiveSceneAssets/scene-kernel.js), which owns
 * the renderer, camera, lights, tour, labels, and the window.liveScene contract. The kernel format exists because the
 * model's output tokens are what a render waits on, and most of a whole page is the same code every time.
 */
export const liveSceneFormatSchema = z.enum(["page", "kernel"]).default("page");

export type LiveSceneFormat = z.infer<typeof liveSceneFormatSchema>;

/** The kernel's address in the app bundle, served at clicky-asset://three/ like three.js itself. */
const sceneKernelURL = "clicky-asset://three/scene-kernel.js";

/** JSON written into a module script, with every "<" escaped, so no string the model wrote can close the script. */
function scriptJSON(value: unknown): string {
  return JSON.stringify(value).replaceAll("<", "\\u003c");
}

/** The page the app loads for a kernel scene: the import map, then one module script that starts the kernel. */
export function sceneKernelPage(kind: LiveSceneRequestKind, answerLabel: string, buildCode: string): string {
  return [
    "<!DOCTYPE html>",
    '<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">',
    '<script type="importmap">{ "imports": { "three": "clicky-asset://three/three.module.js" } }</script>',
    "</head><body>",
    '<script type="module">',
    `import { startScene } from "${sceneKernelURL}";`,
    buildCode,
    `startScene({ kind: ${scriptJSON(kind)}, answerLabel: ${scriptJSON(answerLabel)}, build });`,
    "</script>",
    "</body></html>",
  ].join("\n");
}

// What a simulation's build(kit) must return, in the shape each definition has, as simulationMarkers does for a page.
const kernelSimulationMarkers = [
  { name: "controls", pattern: /\bcontrols\s*[:=]/ },
  { name: "setup", pattern: /\bsetup\s*[(:=]/ },
  { name: "simulate", pattern: /\bsimulate\s*[(:=]/ },
  { name: "readouts", pattern: /\breadouts\s*[:=]/ },
  { name: "kit.lab or kit.field", pattern: /\bkit\.(?:lab|field)\s*\(/ },
] as const;

/** Checks a kernel reply's code and quiz, and returns the page that runs them. */
export function checkLiveSceneKernelReply(modelReply: string, kind: LiveSceneRequestKind = "model"): CheckedLiveSceneReply {
  const codeMatch = modelReply.match(/```(?:js|javascript)\s*([\s\S]*?)```/);
  const jsonMatch = modelReply.match(/```json\s*([\s\S]*?)```/);
  const buildCode = codeMatch?.[1]?.trim();
  const jsonText = jsonMatch?.[1]?.trim();
  if (buildCode === undefined || buildCode.length === 0 || jsonText === undefined || jsonText.length === 0 || (codeMatch?.index ?? 0) > (jsonMatch?.index ?? 0)) {
    return { accepted: false, reason: "The reply must be a js block followed by a json block" };
  }
  if (!/\bfunction\s+build\s*\(/.test(buildCode)) {
    return { accepted: false, reason: "The code must declare function build(kit)" };
  }
  // The kernel owns window.liveScene, and a closing script tag would end the page's script early.
  if (/\bliveScene\b/.test(buildCode)) {
    return { accepted: false, reason: "The code must not touch window.liveScene, which the kernel defines" };
  }
  if (/<\/script/i.test(buildCode)) {
    return { accepted: false, reason: "The code must not contain a closing script tag" };
  }
  if (hasADisallowedURL(buildCode)) {
    return { accepted: false, reason: "The code contains a URL other than the SVG namespace" };
  }
  let program: ReturnType<typeof parseJavaScript>;
  try {
    program = parseJavaScript(buildCode, { ecmaVersion: "latest", sourceType: "module" });
  } catch (parseError) {
    return { accepted: false, reason: `The code does not parse: ${parseError instanceof Error ? parseError.message : String(parseError)}` };
  }
  if (program.body.some((statement) => statement.type === "ImportDeclaration" || statement.type.startsWith("Export")) || /\bimport\s*\(/.test(buildCode)) {
    return { accepted: false, reason: "The code must not import or export anything" };
  }
  if (kind === "simulation") {
    const missingMarker = kernelSimulationMarkers.find((marker) => !marker.pattern.test(buildCode));
    if (missingMarker !== undefined) {
      return { accepted: false, reason: `The simulation code is missing ${missingMarker.name}` };
    }
    const drawnControl = controlElementDrawnIn(buildCode);
    if (drawnControl !== undefined) {
      return { accepted: false, reason: `The simulation code draws its own control (${drawnControl}), and the app draws the only panel` };
    }
  }
  const parsedQuiz = parsedQuizBlock(jsonText);
  if (!parsedQuiz.ok) {
    return { accepted: false, reason: parsedQuiz.reason };
  }
  // The kernel shows "?" on the part registered with the answer label, so a label the code never uses leaves no question mark.
  if (kind === "model" && !buildCode.toLowerCase().includes(parsedQuiz.quiz.answerLabel.trim().toLowerCase())) {
    return { accepted: false, reason: `No part is registered with the answer label ${parsedQuiz.quiz.answerLabel}` };
  }
  return { accepted: true, html: sceneKernelPage(kind, parsedQuiz.quiz.answerLabel, buildCode), quiz: parsedQuiz.quiz };
}
