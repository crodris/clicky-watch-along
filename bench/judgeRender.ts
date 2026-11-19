// What judge.ts shows the judging models: each reply drawn over its frame, a plain description of it, and the
// instructions. No side label or model name reaches any of it. Pure, so judgeRender.test.ts checks it without Chrome.

import type { Verdict } from "./judgePairs.ts";

export type JudgeContext =
  | { kind: "frameParts"; frameBase64: string; width: number; height: number }
  | { kind: "pictureFlows"; frameBase64: string; width: number; height: number; partLabels: string[] }
  | { kind: "quizPlan"; title: string; transcript: string }
  | { kind: "chat"; frameBase64: string; width: number; height: number; systemPrompt: string; history: string; question: string }
  | {
      kind: "liveScene";
      /** A 3D model of the subject, or a simulation the learner can run, as the request's kind says. */
      sceneKind: "model" | "simulation";
      question: string;
      screenshotBase64: string;
      screenshotMediaType: "image/jpeg" | "image/png";
    };

/** The routes the judge can compare, which are the ones whose quality a pass or fail check cannot see. */
export const judgedRoutes = ["/video-frame-parts", "/picture-flows", "/video-quiz-plan", "/chat", "/live-scene"];

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseJSON(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

function numberOr(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function chatTextOf(content: unknown): string {
  if (typeof content === "string") {
    return content;
  }
  return (Array.isArray(content) ? content : []).filter(isRecord).filter((block) => block.type === "text").map((block) => String(block.text)).join("\n");
}

/** Reads what a case asked from the request body bench.ts saved, so the judge needs no copy of the fixtures. */
export function contextFromRequest(route: string, requestBody: unknown): JudgeContext | undefined {
  if (!isRecord(requestBody)) {
    return undefined;
  }
  if ((route === "/video-frame-parts" || route === "/picture-flows") && typeof requestBody.frameBase64 === "string") {
    const frame = { frameBase64: requestBody.frameBase64, width: numberOr(requestBody.frameWidth, 1280), height: numberOr(requestBody.frameHeight, 720) };
    if (route === "/video-frame-parts") {
      return { kind: "frameParts", ...frame };
    }
    const partLabels = Array.isArray(requestBody.partLabels) ? requestBody.partLabels.map(String) : [];
    return { kind: "pictureFlows", ...frame, partLabels };
  }
  if (route === "/video-quiz-plan" && typeof requestBody.title === "string" && Array.isArray(requestBody.transcriptLines)) {
    const transcript = requestBody.transcriptLines
      .filter(isRecord)
      .map((line) => `[${numberOr(line.seconds, 0)}] ${String(line.text)}`)
      .join("\n");
    return { kind: "quizPlan", title: requestBody.title, transcript };
  }
  if (route === "/chat" && Array.isArray(requestBody.messages)) {
    const messages = requestBody.messages.filter(isRecord);
    const lastMessage = messages[messages.length - 1];
    const lastBlocks = Array.isArray(lastMessage?.content) ? lastMessage.content.filter(isRecord) : [];
    const imageBlock = lastBlocks.find((block) => block.type === "image");
    const imageSource = isRecord(imageBlock?.source) ? imageBlock.source : undefined;
    if (typeof imageSource?.data !== "string") {
      return undefined;
    }
    const textBlocks = lastBlocks.filter((block) => block.type === "text").map((block) => String(block.text));
    const dimensions = textBlocks.join(" ").match(/image dimensions: (\d+)x(\d+)/);
    const system = requestBody.system;
    const systemPrompt = typeof system === "string" ? system : chatTextOf(system);
    const history = messages
      .slice(0, -1)
      .map((message) => `${message.role === "assistant" ? "Clicky" : "User"}: ${chatTextOf(message.content)}`)
      .join("\n");
    return {
      kind: "chat",
      frameBase64: imageSource.data,
      width: dimensions === null ? 1280 : Number(dimensions[1]),
      height: dimensions === null ? 800 : Number(dimensions[2]),
      systemPrompt,
      history,
      // The last text block is the transcript, after the screen's caption.
      question: textBlocks[textBlocks.length - 1] ?? "",
    };
  }
  if (route === "/live-scene" && typeof requestBody.question === "string" && typeof requestBody.screenshotBase64 === "string") {
    return {
      kind: "liveScene",
      sceneKind: requestBody.kind === "simulation" ? "simulation" : "model",
      question: requestBody.question,
      screenshotBase64: requestBody.screenshotBase64,
      screenshotMediaType: requestBody.screenshotMediaType === "image/png" ? "image/png" : "image/jpeg",
    };
  }
  return undefined;
}

// ---------- Drawing a reply over its frame ----------

const flowColorCodes: Record<string, string> = {
  blue: "#3b82f6",
  red: "#ef4444",
  orange: "#f97316",
  cyan: "#06b6d4",
  green: "#22c55e",
  yellow: "#eab308",
  white: "#ffffff",
};

function escapeHTML(text: string): string {
  return text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
}

/** A label on a dark pill, placed right of its point or left of it near the frame's right edge. */
function labelAt(x: number, y: number, text: string, frameWidth: number): string {
  const approximateWidth = text.length * 11 + 16;
  const labelLeft = x + 16 + approximateWidth > frameWidth ? x - 16 - approximateWidth : x + 16;
  return (
    `<rect x="${labelLeft}" y="${y - 15}" width="${approximateWidth}" height="30" rx="8" fill="#101820" fill-opacity="0.85"/>` +
    `<text x="${labelLeft + 8}" y="${y + 6}" font-size="18" font-family="Helvetica, Arial, sans-serif" fill="#ffffff">${escapeHTML(text)}</text>`
  );
}

function dot(x: number, y: number, fill: string): string {
  return `<circle cx="${x}" cy="${y}" r="10" fill="${fill}" stroke="#ffffff" stroke-width="3"/>`;
}

function framePartsShapes(replyJSON: unknown, frameWidth: number): string {
  if (!isRecord(replyJSON) || replyJSON.subjectFound !== true) {
    return "";
  }
  const box = isRecord(replyJSON.subjectBox) ? replyJSON.subjectBox : {};
  const left = numberOr(box.left, 0);
  const top = numberOr(box.top, 0);
  const rectangle = `<rect x="${left}" y="${top}" width="${numberOr(box.right, 0) - left}" height="${numberOr(box.bottom, 0) - top}" fill="none" stroke="#00e5ff" stroke-width="4" stroke-dasharray="14 8"/>`;
  const parts = (Array.isArray(replyJSON.parts) ? replyJSON.parts : []).filter(isRecord);
  return (
    rectangle +
    parts
      .map((part, partIndex) => {
        const x = numberOr(part.x, 0);
        const y = numberOr(part.y, 0);
        return dot(x, y, "#ef4444") + labelAt(x, y, `${partIndex + 1} ${String(part.label)}`, frameWidth);
      })
      .join("")
  );
}

function pictureFlowsShapes(replyJSON: unknown, frameWidth: number): string {
  const flows = (isRecord(replyJSON) && Array.isArray(replyJSON.flows) ? replyJSON.flows : []).filter(isRecord);
  return flows
    .map((flow, flowIndex) => {
      const points = (Array.isArray(flow.points) ? flow.points : [])
        .filter((point): point is [number, number] => Array.isArray(point) && typeof point[0] === "number" && typeof point[1] === "number");
      if (points.length < 2) {
        return "";
      }
      const color = flowColorCodes[String(flow.color)] ?? "#ffffff";
      const pointText = points.map(([x, y]) => `${x},${y}`).join(" ");
      const [startX, startY] = points[0];
      const [endX, endY] = points[points.length - 1];
      const [beforeEndX, beforeEndY] = points[points.length - 2];
      // The arrowhead's tip is the stream's last point, and its base sits 24 pixels back along the last segment.
      const heading = Math.atan2(endY - beforeEndY, endX - beforeEndX);
      const baseCenterX = endX - Math.cos(heading) * 24;
      const baseCenterY = endY - Math.sin(heading) * 24;
      const arrowhead = [
        [endX, endY],
        [baseCenterX - Math.sin(heading) * 12, baseCenterY + Math.cos(heading) * 12],
        [baseCenterX + Math.sin(heading) * 12, baseCenterY - Math.cos(heading) * 12],
      ]
        .map(([cornerX, cornerY]) => `${cornerX.toFixed(0)},${cornerY.toFixed(0)}`)
        .join(" ");
      return (
        `<polyline points="${pointText}" fill="none" stroke="#101820" stroke-width="12" stroke-linecap="round" stroke-linejoin="round"/>` +
        `<polyline points="${pointText}" fill="none" stroke="${color}" stroke-width="7" stroke-linecap="round" stroke-linejoin="round"/>` +
        `<polygon points="${arrowhead}" fill="${color}" stroke="#101820" stroke-width="3"/>` +
        dot(startX, startY, color) +
        labelAt(startX, startY, `${flowIndex + 1}`, frameWidth)
      );
    })
    .join("");
}

/** The point a /chat reply moves the cursor to, or undefined for none. The tag is [POINT:x,y:label] or [POINT:none]. */
export function pointInChatReply(replyText: string): { x: number; y: number; label: string } | undefined {
  const pointMatch = replyText.match(/\[POINT:(\d+),(\d+)(?::([^:\]]*))?/);
  return pointMatch === null ? undefined : { x: Number(pointMatch[1]), y: Number(pointMatch[2]), label: pointMatch[3] ?? "" };
}

function chatShapes(replyText: string, frameWidth: number): string {
  const point = pointInChatReply(replyText);
  if (point === undefined) {
    return "";
  }
  return (
    `<circle cx="${point.x}" cy="${point.y}" r="26" fill="none" stroke="#ef4444" stroke-width="5"/>` +
    dot(point.x, point.y, "#ef4444") +
    (point.label === "" ? "" : labelAt(point.x, point.y + 40, point.label, frameWidth))
  );
}

/**
 * A page of exactly the frame's size, with the reply drawn over the frame. Undefined for a reply with no picture, and for a
 * live scene, whose own page judge.ts screenshots with sceneShots.ts.
 */
export function overlayPage(context: JudgeContext, replyText: string): { html: string; width: number; height: number } | undefined {
  if (context.kind === "quizPlan" || context.kind === "liveScene") {
    return undefined;
  }
  const replyJSON = context.kind === "chat" ? undefined : parseJSON(replyText);
  const shapes =
    context.kind === "frameParts"
      ? framePartsShapes(replyJSON, context.width)
      : context.kind === "pictureFlows"
        ? pictureFlowsShapes(replyJSON, context.width)
        : chatShapes(replyText, context.width);
  const { width, height } = context;
  const html =
    `<!doctype html><meta charset="utf-8"><style>html,body{margin:0;width:${width}px;height:${height}px;overflow:hidden;background:#000}` +
    `img,svg{position:absolute;left:0;top:0}</style>` +
    `<img width="${width}" height="${height}" src="data:image/jpeg;base64,${context.frameBase64}">` +
    `<svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">${shapes}</svg>`;
  return { html, width, height };
}

// ---------- Describing a reply in words ----------

function describeFrameParts(replyText: string): string {
  const replyJSON = parseJSON(replyText);
  if (!isRecord(replyJSON)) {
    return `The reply was not JSON: ${replyText.slice(0, 300)}`;
  }
  if (replyJSON.subjectFound !== true) {
    return "subjectFound: false (the reply says the frame has no single subject)";
  }
  const parts = (Array.isArray(replyJSON.parts) ? replyJSON.parts : []).filter(isRecord);
  return [
    `subjectFound: true`,
    `isArtwork: ${String(replyJSON.isArtwork)}`,
    `wholePictureIsSubject: ${String(replyJSON.wholePictureIsSubject)}`,
    `pictureShowsDepth: ${String(replyJSON.pictureShowsDepth)}`,
    `${parts.length} parts:`,
    ...parts.map((part, partIndex) => `${partIndex + 1}. ${String(part.label)}${part.isQuizAnswer === true ? " (the quiz answer)" : ""}`),
  ].join("\n");
}

function describePictureFlows(replyText: string): string {
  const replyJSON = parseJSON(replyText);
  if (!isRecord(replyJSON) || !Array.isArray(replyJSON.flows)) {
    return `The reply was not JSON with a flows list: ${replyText.slice(0, 300)}`;
  }
  const flows = replyJSON.flows.filter(isRecord);
  return flows.length === 0
    ? "No flows (the reply says nothing in the picture flows)"
    : [`${flows.length} flows:`, ...flows.map((flow, flowIndex) => `${flowIndex + 1}. ${String(flow.style)} in ${String(flow.color)}, ${Array.isArray(flow.points) ? flow.points.length : 0} points`)].join("\n");
}

function describeQuizPlan(replyText: string): string {
  const replyJSON = parseJSON(replyText);
  if (!isRecord(replyJSON) || !Array.isArray(replyJSON.moments)) {
    return `The reply was not JSON with a moments list: ${replyText.slice(0, 300)}`;
  }
  return replyJSON.moments
    .filter(isRecord)
    .map(
      (moment, momentIndex) =>
        `${momentIndex + 1}. Pause at ${String(moment.pauseAtSeconds)}s, answer stated at ${String(moment.sourceLineSeconds)}s.\n` +
        `   Question: ${String(moment.question)}\n   Answer: ${String(moment.answerLabel)}\n   Explanation: ${String(moment.explanation)}`,
    )
    .join("\n");
}

/** The page itself is judged from its screenshots, so the words give only the quiz the page came with. */
function describeLiveScene(replyText: string): string {
  const replyJSON = parseJSON(replyText);
  if (!isRecord(replyJSON) || typeof replyJSON.html !== "string") {
    return `The reply had no page: ${replyText.slice(0, 300)}`;
  }
  const quiz = isRecord(replyJSON.quiz) ? replyJSON.quiz : {};
  return [
    `Quiz question: ${String(quiz.question)}`,
    `Answer label: ${String(quiz.answerLabel)}`,
    `Explanation: ${String(quiz.explanation)}`,
  ].join("\n");
}

function describeChat(replyText: string): string {
  const point = pointInChatReply(replyText);
  const spokenText = replyText.replace(/\[POINT:[^\]]*\]/g, "").trim();
  return `Spoken: ${spokenText}\n${point === undefined ? "The cursor does not move." : `The cursor moves to (${point.x}, ${point.y})${point.label === "" ? "" : ` and the tag names it "${point.label}"`}.`}`;
}

export function describeReply(context: JudgeContext, replyText: string): string {
  switch (context.kind) {
    case "frameParts":
      return describeFrameParts(replyText);
    case "pictureFlows":
      return describePictureFlows(replyText);
    case "quizPlan":
      return describeQuizPlan(replyText);
    case "chat":
      return describeChat(replyText);
    case "liveScene":
      return describeLiveScene(replyText);
  }
}

// ---------- Instructions ----------

export const judgeSystemPrompt = [
  "You compare two replies, A and B, to the same request, for the purpose and criteria you are given.",
  "You are not told which model wrote either reply. Judge only the quality of what each reply would give the learner.",
  "Do not prefer a reply for its position, its length, or its tone, unless the criteria say so.",
  "Answer with a reason of at most two sentences, then the winner: A, B, or tie. Use tie only when you cannot tell the two apart in quality.",
].join("\n");

const criteriaByKind: Record<Exclude<JudgeContext["kind"], "liveScene">, string> = {
  frameParts: [
    "Purpose: a learning app lifts the main subject out of a video frame in 3D and labels its parts for a 10-year-old.",
    "In each picture, the dashed cyan rectangle is the subject's box, and each numbered red dot is where a part label's line touches the picture. The text under each picture gives the flags and the part names.",
    "A better reply:",
    "- Boxes the one subject tightly, without the text, hands, or other drawings around it. For a painting of a whole scene, the box covers the whole painted area.",
    "- Puts every dot inside the part it names, not on a neighbor or on empty background.",
    "- Names parts in two or three plain words a 10-year-old knows, and covers the subject's main parts.",
    "- Sets the flags right. isArtwork is true for a painting, print, drawing, or sculpture. wholePictureIsSubject is true only for a painted scene of many figures or a landscape, never for one animal or object on a plain background. pictureShowsDepth is true for a 3D render, a photo, or a 3D cutaway, and false for flat diagrams and paintings.",
    "- Says there is no subject only when the frame holds no single drawn or filmed object, such as a chart or a person talking.",
  ].join("\n"),
  pictureFlows: [
    "Purpose: a learning app draws moving streams on top of a picture, to show what flows through its subject.",
    "In each picture, every colored line is one stream, numbered at its round start and ending in an arrowhead. The text under each picture lists each stream's color and style.",
    "A better reply:",
    "- Routes each line through the channels, vessels, or pipes the picture draws, not across walls or empty space, in the direction the substance really moves.",
    "- Uses the right color for what flows: blue for cool air or blood low in oxygen, red for blood rich in oxygen, orange for hot gas or heat, cyan for water, green for sap or food, yellow for electric current, and white for anything else.",
    "- Uses the right style: smoke, sparks, lava, droplets, air, current, or beads.",
    "- Covers the main flows without piling up redundant lines.",
    "- Returns no flow at all when nothing in the picture flows, such as a bicycle, whose moving parts are solid.",
  ].join("\n"),
  quizPlan: [
    "Purpose: a learning app pauses a video the learner is watching and asks one quiz question at each moment in the plan.",
    "The transcript is the only source of truth. Each line starts with its time in seconds.",
    "A better plan:",
    "- Asks only about facts the transcript states before the pause, and never uses outside knowledge.",
    "- Pauses right after a concrete idea finishes, never mid-explanation, never during a sponsor read or an ad, and never after a request to like and subscribe.",
    "- Starts early, with the first moment 20 to 60 seconds in when a real fact allows, then spreads the rest out with long stretches of watching between them.",
    "- Asks questions a curious learner can answer aloud in a few words, in at most two sentences, that neither contain nor hint at the answer.",
    "- Gives each moment a one or two word noun as its answer, and an explanation that is true to the transcript.",
    "- Has a sensible number of moments for the video's length, each about a different fact.",
  ].join("\n"),
  chat: [
    "Purpose: Clicky is a voice companion that sees the user's screen. The user asked a question by voice, and Clicky answers out loud.",
    "A [POINT:x,y:label] tag moves a cursor to that spot in the screenshot. It is drawn as a red dot with a ring.",
    "A better reply:",
    "- Is correct and useful for what the screen actually shows, and makes up nothing that is not on it.",
    "- Follows the style rules in Clicky's system prompt below.",
    "- Points the cursor at the right element when pointing helps, with the dot on that element, and does not point when nothing on screen fits.",
  ].join("\n"),
};

const liveSceneCriteria: Record<"model" | "simulation", string> = {
  model: [
    "Purpose: a learning app builds an interactive 3D model of what the learner asked about, from the screenshot of what they were watching, and tours it with labels for a 10-year-old.",
    "Each reply is the page a model wrote, shown in two screenshots: when the camera tour ends, and after the camera turns half way around.",
    "A better page:",
    "- Shows the subject the learner asked about, recognizable at a glance, with the right shape, proportions, and parts, true to the screenshot.",
    "- Looks finished: solid lighting and materials, the subject large and framed in view, and no blank, black, broken, or cut-off view.",
    "- Places each label on the part it names, in plain words, without labels piled on top of each other.",
    "- Holds up from the other side, with no missing faces or parts floating apart.",
    "- Has a quiz question a learner can answer from the model, whose answer label is a part the page shows.",
  ].join("\n"),
  simulation: [
    "Purpose: a learning app builds a science experiment the learner can run, from the screenshot of what they were watching. The app adds its own sliders and buttons, so the page shows only the experiment.",
    "Each reply is the page a model wrote, shown in two screenshots: when the camera tour ends, and after one run of the experiment at its starting settings.",
    "A better page:",
    "- Builds equipment that fits the topic in the screenshot, recognizable, at a sensible size, with the equipment large and in view.",
    "- Draws a setting that fits, such as a lab bench for a tabletop experiment or a field for one that covers many meters.",
    "- Shows the run happening: what moves has moved, a traced path or a changed reading is visible, and the result is plausible for the physics.",
    "- Looks finished, with no blank, black, broken, or cut-off view.",
    "- Has a hypothesis question that the experiment can answer by changing one setting.",
  ].join("\n"),
};

function criteriaFor(context: JudgeContext): string {
  return context.kind === "liveScene" ? liveSceneCriteria[context.sceneKind] : criteriaByKind[context.kind];
}

export type JudgePromptPart =
  | { kind: "text"; text: string }
  | { kind: "image"; base64: string; mediaType: "image/jpeg" | "image/png" };

export type JudgedReply = { description: string; overlayPNGBase64: string | undefined };

/** The whole user turn of one judging call: the request, the criteria, the clean frame, then reply A and reply B. */
export function judgePromptParts(context: JudgeContext, replyA: JudgedReply, replyB: JudgedReply): JudgePromptPart[] {
  const parts: JudgePromptPart[] = [{ kind: "text", text: criteriaFor(context) }];
  if (context.kind === "liveScene") {
    parts.push({ kind: "text", text: `The learner said: "${context.question}". This is the screen they were watching:` });
    parts.push({ kind: "image", base64: context.screenshotBase64, mediaType: context.screenshotMediaType });
  } else if (context.kind === "quizPlan") {
    parts.push({ kind: "text", text: `Video title: ${context.title}\nTranscript:\n${context.transcript}` });
  } else if (context.kind === "pictureFlows") {
    parts.push({ kind: "text", text: `The picture's parts are: ${context.partLabels.join(", ")}. The frame below is ${context.width} by ${context.height} pixels.` });
    parts.push({ kind: "image", base64: context.frameBase64, mediaType: "image/jpeg" });
  } else if (context.kind === "frameParts") {
    parts.push({ kind: "text", text: `The frame below is ${context.width} by ${context.height} pixels.` });
    parts.push({ kind: "image", base64: context.frameBase64, mediaType: "image/jpeg" });
  } else {
    parts.push({
      kind: "text",
      text: `Clicky's system prompt:\n${context.systemPrompt}\n\n${context.history === "" ? "" : `The conversation so far:\n${context.history}\n\n`}The user said: ${context.question}\nThe screenshot below is ${context.width} by ${context.height} pixels.`,
    });
    parts.push({ kind: "image", base64: context.frameBase64, mediaType: "image/jpeg" });
  }
  for (const [replyName, reply] of [["A", replyA], ["B", replyB]] as const) {
    const pictureNote = reply.overlayPNGBase64 === undefined ? "" : context.kind === "liveScene" ? ", two screenshots of its page" : ", drawn over the frame";
    parts.push({ kind: "text", text: `Reply ${replyName}${pictureNote}:\n${reply.description}` });
    if (reply.overlayPNGBase64 !== undefined) {
      parts.push({ kind: "image", base64: reply.overlayPNGBase64, mediaType: "image/png" });
    }
  }
  return parts;
}

/** The reason comes first in the schema, so the model writes it before it picks. */
export const judgeVerdictSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    reason: { type: "string" },
    winner: { type: "string", enum: ["A", "B", "tie"] },
  },
  required: ["reason", "winner"],
};

export function parseJudgeVerdict(replyText: string): { winner: Verdict; reason: string } | undefined {
  const verdictJSON = parseJSON(replyText);
  if (!isRecord(verdictJSON) || (verdictJSON.winner !== "A" && verdictJSON.winner !== "B" && verdictJSON.winner !== "tie")) {
    return undefined;
  }
  return { winner: verdictJSON.winner, reason: typeof verdictJSON.reason === "string" ? verdictJSON.reason : "" };
}

// ---------- The spot-check page ----------

export type SpotCheckReply = { description: string; imageFileName: string | undefined };

export type SpotCheckCard = {
  title: string;
  /** What the case asked, so a reader can judge the pair without the fixtures. */
  request: string;
  /** In the order shown, which the page does not explain until its reveal. */
  replies: [SpotCheckReply, SpotCheckReply];
  /** Which side was A and B, and what each judge said. Shown only when the reader opens it. */
  reveal: string;
};

/** One page where a reader picks a winner for each pair first, then opens the reveal to compare with the judges. */
export function spotCheckPage(cards: SpotCheckCard[]): string {
  const cardHTML = cards
    .map((card, cardIndex) => {
      const replyColumns = card.replies
        .map(
          (reply, replyIndex) =>
            `<section><h3>${replyIndex === 0 ? "A" : "B"}</h3>` +
            (reply.imageFileName === undefined ? "" : `<img src="images/${escapeHTML(reply.imageFileName)}" alt="">`) +
            `<pre>${escapeHTML(reply.description)}</pre></section>`,
        )
        .join("");
      return (
        `<article><h2>${cardIndex + 1}. ${escapeHTML(card.title)}</h2><p>${escapeHTML(card.request)}</p>` +
        `<div class="pair">${replyColumns}</div>` +
        `<details><summary>Reveal the sides and the judges' verdicts</summary><pre>${escapeHTML(card.reveal)}</pre></details></article>`
      );
    })
    .join("\n");
  return (
    `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">` +
    `<title>Judge spot check</title>` +
    `<style>:root{color-scheme:light dark;font-family:-apple-system,Helvetica,Arial,sans-serif}body{margin:24px auto;max-width:1400px;padding:0 16px}` +
    `article{border-top:2px solid #8884;padding:16px 0}.pair{display:grid;grid-template-columns:1fr 1fr;gap:16px}` +
    `img{width:100%;height:auto;border-radius:6px}pre{white-space:pre-wrap;font-size:14px}details{margin-top:8px}</style>` +
    `<h1>Judge spot check</h1><p>Pick the better reply in each pair before you open its reveal.</p>${cardHTML}</html>`
  );
}
