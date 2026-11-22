import { parse as parseJavaScript } from "acorn";
import { z } from "zod";
import { zodIssueCodesByPath } from "./anthropic";

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
    const lowercaseHTMLForControls = html.toLowerCase();
    const drawnControl = controlElementsASimulationMustNotDraw.find((controlElement) => controlElement.pattern.test(lowercaseHTMLForControls));
    if (drawnControl !== undefined) {
      return { accepted: false, reason: `The simulation page draws its own control (${drawnControl.description}), and the app draws the only panel` };
    }
  }

  // A typo in the generated script stops the page before it draws, and the app would wait
  // for a tour that never ends. About 1 in 10 pages had one on 2026-11-03, so check here and let the retry run.
  const scriptSyntaxError = firstScriptSyntaxError(html);
  if (scriptSyntaxError !== undefined) {
    return { accepted: false, reason: `A page script does not parse: ${scriptSyntaxError}` };
  }

  const lowercaseHTML = html.toLowerCase();
  // The namespace has to end here. A longer host that only starts with it is still a URL.
  const htmlWithoutTheSvgNamespace = lowercaseHTML.replace(
    new RegExp(`https?:\\/\\/${svgNamespacePrefix}\\/?(?=$|[^a-z0-9._~-])`, "g"),
    "",
  );
  const htmlHasADisallowedURL = ["http://", "https://", "ws://", "wss://", "stun:", "stuns:", "turn:", "turns:", "rtcpeerconnection", "<iframe"].some((urlPrefix) =>
    htmlWithoutTheSvgNamespace.includes(urlPrefix),
  );
  if (htmlHasADisallowedURL) {
    return { accepted: false, reason: "The page contains a URL other than the SVG namespace" };
  }

  let quizJSON: unknown;
  try {
    quizJSON = JSON.parse(jsonText);
  } catch {
    return { accepted: false, reason: "The json block did not parse" };
  }

  const parsedQuiz = liveSceneQuizSchema.safeParse(quizJSON);
  if (!parsedQuiz.success) {
    // The reason goes into the Worker log and the 422 body, so it names each problem by field and issue code and never
    // quotes the model's own value, which could carry instructions to anything that reads the reason.
    return { accepted: false, reason: `The json block breaks the quiz schema at ${zodIssueCodesByPath(parsedQuiz.error)}` };
  }

  return { accepted: true, html, quiz: parsedQuiz.data };
}
