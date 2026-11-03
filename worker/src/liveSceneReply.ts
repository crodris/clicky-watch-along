import { parse as parseJavaScript } from "acorn";
import { z } from "zod";

export const liveSceneQuizSchema = z.object({
  question: z.string().min(1),
  answerLabel: z.string().min(1),
  functionWords: z.array(z.string()),
  explanation: z.string().min(1),
});

export type LiveSceneQuiz = z.infer<typeof liveSceneQuizSchema>;

export type CheckedLiveSceneReply =
  | { accepted: true; html: string; quiz: LiveSceneQuiz }
  | { accepted: false; reason: string };

const pageMarkersTheAppCalls = ["liveScene", "tourFinished", "reveal", "zoomBy", "focusPart"] as const;

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

export function checkLiveSceneModelReply(modelReply: string): CheckedLiveSceneReply {
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
    return { accepted: false, reason: parsedQuiz.error.message };
  }

  return { accepted: true, html, quiz: parsedQuiz.data };
}
