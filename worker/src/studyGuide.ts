/**
 * POST /study-guide
 *
 * The app sends a YouTube video's timestamped transcript, the quiz results so far, and optionally a
 * focus or a revision instruction. Sonnet drafts a study guide as JSON, and the Worker writes it to
 * Notion as its own page in the token owner's Private section. NOTION_API_KEY must be a personal access token,
 * because only a token that acts as a user may create a page with no parent page. A revision creates the new
 * page first, then trashes the page it replaces, so a failure never leaves the learner without a guide.
 *
 * parseStudyGuide is the only place the model reply is trusted. studyGuidePageBlocks builds the page, and
 * the "Review these first" section comes from the quiz results in code, never from the model.
 */

import { z } from "zod";
import { jsonResponse, parseJSONRequest, requestAnthropicReplyJSON, zodIssuesOnOneLine } from "./anthropic";
import { lineStartAtOrBefore } from "./videoQuizPlan";

const youTubeHostNames = new Set(["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"]);

function isYouTubeVideoURL(videoURL: string): boolean {
  try {
    const parsedURL = new URL(videoURL);
    return parsedURL.protocol === "https:" && youTubeHostNames.has(parsedURL.hostname);
  } catch {
    return false;
  }
}

const transcriptLineSchema = z.object({
  seconds: z.number().nonnegative(),
  text: z.string(),
});

const studyGuideSchema = z.object({
  title: z.string().trim().min(1).max(120),
  summary: z.string().trim().min(1),
  sections: z
    .array(
      z.object({
        heading: z.string().trim().min(1),
        points: z
          .array(z.object({ text: z.string().trim().min(1), seconds: z.number().nonnegative() }))
          .min(1)
          .max(6),
      }),
    )
    .min(1)
    .max(6),
  keyTerms: z
    .array(z.object({ term: z.string().trim().min(1), meaning: z.string().trim().min(1), seconds: z.number().nonnegative() }))
    .max(10),
});

const quizResultSchema = z.object({
  question: z.string(),
  answerLabel: z.string(),
  explanation: z.string(),
  askedAtSeconds: z.number(),
  result: z.enum(["gotIt", "missed", "skipped"]),
});

const studyGuideRequestSchema = z.object({
  videoTitle: z.string().trim().min(1),
  videoURL: z.string().refine(isYouTubeVideoURL, { message: "videoURL must be an https YouTube URL" }),
  transcriptLines: z.array(transcriptLineSchema).min(1),
  quizResults: z.array(quizResultSchema).max(20),
  focus: z.string().max(300).optional(),
  revision: z
    .object({
      pageHandle: z.string().min(1),
      previousGuide: studyGuideSchema,
      instruction: z.string().trim().min(1).max(300),
    })
    .optional(),
});

type TranscriptLine = z.infer<typeof transcriptLineSchema>;
export type StudyGuide = z.infer<typeof studyGuideSchema>;
export type QuizResult = z.infer<typeof quizResultSchema>;
type StudyGuideRequest = z.infer<typeof studyGuideRequestSchema>;

type StudyGuideParseResult =
  | { ok: true; guide: StudyGuide }
  | { ok: false; error: string };

const maximumGuideAttempts = 3;

/** Structured output schema. Count and length rules stay in parseStudyGuide, which names the broken rule on a retry. */
const guideOutputSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    title: { type: "string", description: "The page title, at most 120 characters." },
    summary: { type: "string", description: "Two to four plain sentences on what the video is about." },
    sections: {
      type: "array",
      description: "One to six sections, in the order the video covers them.",
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          heading: { type: "string" },
          points: {
            type: "array",
            description: "One to six short points a learner can skim.",
            items: {
              type: "object",
              additionalProperties: false,
              properties: {
                text: { type: "string" },
                seconds: {
                  type: "number",
                  description: "The seconds value, copied exactly, of the transcript line that says this point.",
                },
              },
              required: ["text", "seconds"],
            },
          },
        },
        required: ["heading", "points"],
      },
    },
    keyTerms: {
      type: "array",
      description: "Up to ten terms the video defines. Empty when it defines none.",
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          term: { type: "string" },
          meaning: { type: "string", description: "What the video says the term means, in plain words." },
          seconds: {
            type: "number",
            description: "The seconds value, copied exactly, of the transcript line that defines the term.",
          },
        },
        required: ["term", "meaning", "seconds"],
      },
    },
  },
  required: ["title", "summary", "sections", "keyTerms"],
};

const systemPrompt = [
  "You write a study guide for a learner who just watched, or is watching, a video. You read the whole timestamped transcript and reply with the guide as JSON.",
  "",
  "Each transcript line starts with its time in seconds, like [123.4]. Every point and key term has a seconds value. Copy it exactly from the transcript line that says it.",
  "",
  "Rules:",
  "- Use only what the transcript says. Never add outside facts.",
  "- Put sections in the order the video covers them, one to six sections, each with a short heading.",
  "- Write plain words that a 12-year-old follows.",
  "- Keep each point to one short sentence a learner can skim, one to six points per section.",
  "- summary is two to four sentences on what the video is about.",
  "- keyTerms lists up to ten terms the video defines, with the meaning as the video gives it. Use an empty list when the video defines none.",
  "- title is at most 120 characters.",
  "- Skip sponsor reads, ads, and requests to like or subscribe.",
  "",
  "When the learner's quiz results are listed, give more room to the ideas they missed or skipped. Do not list the quiz questions yourself, because the page already has a section for them.",
  "When a focus is given, build the guide around it.",
  "When a previous guide and an instruction are given, apply the instruction to the previous guide and keep everything else as it was.",
].join("\n");

/**
 * Every seconds value moves to the start of the transcript line it falls in, so a link always lands on a line
 * that exists. A time before the first line keeps its value, which the check below rejects as a line the model never saw.
 */
export function parseStudyGuide(guideJSON: unknown, transcriptLines: TranscriptLine[]): StudyGuideParseResult {
  const parsedGuide = studyGuideSchema.safeParse(guideJSON);
  if (!parsedGuide.success) {
    return { ok: false, error: zodIssuesOnOneLine(parsedGuide.error) };
  }

  const lineStartsInOrder = [...new Set(transcriptLines.map((transcriptLine) => transcriptLine.seconds))].sort(
    (earlierSeconds, laterSeconds) => earlierSeconds - laterSeconds,
  );
  const firstLineSeconds = lineStartsInOrder[0];

  const unsnappedGuide = parsedGuide.data;
  const timeBeforeFirstLine = [
    ...unsnappedGuide.sections.flatMap((section) => section.points),
    ...unsnappedGuide.keyTerms,
  ].find((pointOrTerm) => pointOrTerm.seconds < firstLineSeconds);
  if (timeBeforeFirstLine !== undefined) {
    return {
      ok: false,
      error: `seconds ${timeBeforeFirstLine.seconds} is before the first transcript line at ${firstLineSeconds}`,
    };
  }

  const snapSeconds = (secondsToSnap: number) => lineStartAtOrBefore(secondsToSnap, lineStartsInOrder);
  return {
    ok: true,
    guide: {
      ...unsnappedGuide,
      sections: unsnappedGuide.sections.map((section) => ({
        ...section,
        points: section.points.map((point) => ({ ...point, seconds: snapSeconds(point.seconds) })),
      })),
      keyTerms: unsnappedGuide.keyTerms.map((keyTerm) => ({ ...keyTerm, seconds: snapSeconds(keyTerm.seconds) })),
    },
  };
}

/** The video's URL with its `t` query parameter set to whole seconds, so the link opens the video at that moment. */
export function videoTimestampURL(videoURL: string, seconds: number): string {
  const timestampURL = new URL(videoURL);
  timestampURL.searchParams.set("t", `${Math.floor(seconds)}s`);
  return timestampURL.toString();
}

function formatTimestamp(seconds: number): string {
  const wholeSeconds = Math.floor(seconds);
  const hours = Math.floor(wholeSeconds / 3600);
  const minutes = Math.floor((wholeSeconds % 3600) / 60);
  const secondsOfMinute = String(wholeSeconds % 60).padStart(2, "0");
  if (hours > 0) {
    return `${hours}:${String(minutes).padStart(2, "0")}:${secondsOfMinute}`;
  }
  return `${minutes}:${secondsOfMinute}`;
}

// Notion's request shapes, narrowed to the few blocks the page uses.
type NotionRichTextItem = {
  type: "text";
  text: { content: string; link?: { url: string } };
  annotations?: { bold: true };
};

export type NotionBlock =
  | { object: "block"; type: "paragraph"; paragraph: { rich_text: NotionRichTextItem[] } }
  | { object: "block"; type: "heading_2"; heading_2: { rich_text: NotionRichTextItem[] } }
  | { object: "block"; type: "bulleted_list_item"; bulleted_list_item: { rich_text: NotionRichTextItem[] } };

const notionRichTextCharacterLimit = 2000;

function truncatedForNotion(content: string): string {
  if (content.length <= notionRichTextCharacterLimit) {
    return content;
  }
  const truncatedContent = content.slice(0, notionRichTextCharacterLimit);
  const lastCharacterCode = truncatedContent.charCodeAt(notionRichTextCharacterLimit - 1);
  // A high surrogate left at the end is half of an emoji, which Notion would reject.
  const endsInHalfOfAnEmoji = lastCharacterCode >= 0xd800 && lastCharacterCode <= 0xdbff;
  return endsInHalfOfAnEmoji ? truncatedContent.slice(0, -1) : truncatedContent;
}

function richTextItem(content: string, options: { linkURL?: string; bold?: boolean } = {}): NotionRichTextItem {
  return {
    type: "text",
    text: {
      content: truncatedForNotion(content),
      ...(options.linkURL !== undefined ? { link: { url: options.linkURL } } : {}),
    },
    ...(options.bold === true ? { annotations: { bold: true as const } } : {}),
  };
}

function timestampLinkItem(videoURL: string, seconds: number): NotionRichTextItem {
  return richTextItem(` (${formatTimestamp(seconds)})`, { linkURL: videoTimestampURL(videoURL, seconds) });
}

function paragraphBlock(richText: NotionRichTextItem[]): NotionBlock {
  return { object: "block", type: "paragraph", paragraph: { rich_text: richText } };
}

function heading2Block(heading: string): NotionBlock {
  return { object: "block", type: "heading_2", heading_2: { rich_text: [richTextItem(heading)] } };
}

function bulletedListItemBlock(richText: NotionRichTextItem[]): NotionBlock {
  return { object: "block", type: "bulleted_list_item", bulleted_list_item: { rich_text: richText } };
}

/** The page body, top to bottom. At the largest guide this is 76 blocks, under Notion's 100 children per request. */
export function studyGuidePageBlocks(
  guide: StudyGuide,
  quizResults: QuizResult[],
  videoTitle: string,
  videoURL: string,
): NotionBlock[] {
  const resultsToReview = quizResults.filter((quizResult) => quizResult.result !== "gotIt");

  const reviewBlocks =
    resultsToReview.length === 0
      ? []
      : [
          heading2Block("Review these first"),
          ...resultsToReview.map((quizResult) =>
            bulletedListItemBlock([
              richTextItem(quizResult.question),
              richTextItem(`\nAnswer: ${quizResult.answerLabel}. ${quizResult.explanation}`),
              timestampLinkItem(videoURL, quizResult.askedAtSeconds),
            ]),
          ),
        ];

  const sectionBlocks = guide.sections.flatMap((section) => [
    heading2Block(section.heading),
    ...section.points.map((point) =>
      bulletedListItemBlock([richTextItem(point.text), timestampLinkItem(videoURL, point.seconds)]),
    ),
  ]);

  const keyTermBlocks =
    guide.keyTerms.length === 0
      ? []
      : [
          heading2Block("Key terms"),
          ...guide.keyTerms.map((keyTerm) =>
            bulletedListItemBlock([
              richTextItem(keyTerm.term, { bold: true }),
              richTextItem(`: ${keyTerm.meaning}`),
              timestampLinkItem(videoURL, keyTerm.seconds),
            ]),
          ),
        ];

  return [
    paragraphBlock([richTextItem("Study guide for "), richTextItem(videoTitle, { linkURL: videoURL })]),
    paragraphBlock([richTextItem(guide.summary)]),
    ...reviewBlocks,
    ...sectionBlocks,
    ...keyTermBlocks,
  ];
}

const notionAPIBaseURL = "https://api.notion.com/v1";
const notionAPIVersion = "2026-03-11";

const notionPageReplySchema = z.object({ id: z.string(), url: z.string() });

type NotionCallResult<Reply> = { ok: true; reply: Reply } | { ok: false; error: string };

async function callNotion(
  notionAPIKey: string,
  method: "POST" | "PATCH",
  path: string,
  requestBody: unknown,
): Promise<NotionCallResult<unknown>> {
  try {
    const notionResponse = await fetch(`${notionAPIBaseURL}${path}`, {
      method,
      headers: {
        authorization: `Bearer ${notionAPIKey}`,
        "notion-version": notionAPIVersion,
        "content-type": "application/json",
      },
      body: JSON.stringify(requestBody),
    });
    if (!notionResponse.ok) {
      const errorText = await notionResponse.text();
      console.error(`[/study-guide] Notion API error ${notionResponse.status} on ${method} ${path}: ${errorText}`);
      return { ok: false, error: `Notion returned ${notionResponse.status}` };
    }
    return { ok: true, reply: await notionResponse.json() };
  } catch (error) {
    console.error(`[/study-guide] Notion request failed on ${method} ${path}:`, error);
    return { ok: false, error: "Notion could not be reached" };
  }
}

async function createNotionPage(
  notionAPIKey: string,
  title: string,
  children: NotionBlock[],
): Promise<NotionCallResult<{ id: string; url: string }>> {
  const createdPage = await callNotion(notionAPIKey, "POST", "/pages", {
    parent: { type: "workspace", workspace: true },
    properties: { title: { title: [richTextItem(title)] } },
    children,
  });
  if (!createdPage.ok) {
    return createdPage;
  }
  const parsedPage = notionPageReplySchema.safeParse(createdPage.reply);
  if (!parsedPage.success) {
    return { ok: false, error: `Notion's reply was not a page: ${zodIssuesOnOneLine(parsedPage.error)}` };
  }
  return { ok: true, reply: parsedPage.data };
}

function hexFromBytes(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function bytesFromHex(hexText: string): Uint8Array<ArrayBuffer> | undefined {
  if (!/^(?:[0-9a-f]{2})+$/.test(hexText)) {
    return undefined;
  }
  return new Uint8Array((hexText.match(/../g) ?? []).map((hexPair) => Number.parseInt(hexPair, 16)));
}

async function pageHandleSigningKey(notionAPIKey: string): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(notionAPIKey),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

/**
 * The app gets a page handle, the page id with an HMAC of it keyed by the Notion token, instead of the bare id.
 * A revision trashes the page its handle names, and the token can reach every page its owner can, so only a
 * handle this Worker signed may name the page to trash.
 */
export async function signedPageHandle(notionAPIKey: string, pageId: string): Promise<string> {
  const signature = await crypto.subtle.sign(
    "HMAC",
    await pageHandleSigningKey(notionAPIKey),
    new TextEncoder().encode(pageId),
  );
  return `${pageId}.${hexFromBytes(new Uint8Array(signature))}`;
}

/** The page id a handle names, or undefined when this Worker did not sign the handle. */
export async function pageIdFromSignedHandle(notionAPIKey: string, pageHandle: string): Promise<string | undefined> {
  const separatorIndex = pageHandle.lastIndexOf(".");
  if (separatorIndex <= 0) {
    return undefined;
  }
  const pageId = pageHandle.slice(0, separatorIndex);
  const signatureBytes = bytesFromHex(pageHandle.slice(separatorIndex + 1));
  if (signatureBytes === undefined) {
    return undefined;
  }
  const signatureIsValid = await crypto.subtle.verify(
    "HMAC",
    await pageHandleSigningKey(notionAPIKey),
    signatureBytes,
    new TextEncoder().encode(pageId),
  );
  return signatureIsValid ? pageId : undefined;
}

async function trashNotionPage(notionAPIKey: string, pageId: string): Promise<NotionCallResult<unknown>> {
  return await callNotion(notionAPIKey, "PATCH", `/pages/${encodeURIComponent(pageId)}`, { in_trash: true });
}

function userTurn(studyGuideRequest: StudyGuideRequest, rejectedReplyError: string) {
  const transcriptText = studyGuideRequest.transcriptLines
    .map((transcriptLine) => `[${transcriptLine.seconds}] ${transcriptLine.text}`)
    .join("\n");

  const quizResultsText = studyGuideRequest.quizResults
    .map(
      (quizResult) =>
        `- ${quizResult.result} at ${quizResult.askedAtSeconds}s: ${quizResult.question} (answer: ${quizResult.answerLabel})`,
    )
    .join("\n");

  const revision = studyGuideRequest.revision;
  const uncachedTexts = [
    studyGuideRequest.focus !== undefined && studyGuideRequest.focus.trim().length > 0
      ? `Focus: ${studyGuideRequest.focus}`
      : undefined,
    quizResultsText.length > 0 ? `The learner's quiz results:\n${quizResultsText}` : undefined,
    revision !== undefined
      ? [
          `Previous study guide:\n${JSON.stringify(revision.previousGuide)}`,
          `Revise it with this instruction: ${revision.instruction}`,
        ].join("\n\n")
      : undefined,
    rejectedReplyError.length > 0
      ? `Your previous reply was rejected: ${rejectedReplyError}. Reply with the guide again and fix that.`
      : undefined,
  ].filter((text): text is string => text !== undefined);

  return {
    role: "user" as const,
    content: [
      {
        type: "text" as const,
        text: [`Video title: ${studyGuideRequest.videoTitle}`, "", "Transcript:", transcriptText].join("\n"),
        // A retry or a revision sends the same system prompt and transcript, so it reads them from the cache.
        cache_control: { type: "ephemeral" as const },
      },
      ...uncachedTexts.map((text) => ({ type: "text" as const, text })),
    ],
  };
}

export interface StudyGuideEnvironment {
  ANTHROPIC_API_KEY: string;
  NOTION_API_KEY?: string;
}

export async function handleStudyGuide(request: Request, environment: StudyGuideEnvironment): Promise<Response> {
  const parsedRequest = await parseJSONRequest(request, studyGuideRequestSchema);
  if (!parsedRequest.ok) {
    return parsedRequest.response;
  }
  const studyGuideRequest = parsedRequest.requestBody;

  const notionAPIKey = environment.NOTION_API_KEY;
  if (!notionAPIKey) {
    return jsonResponse({ error: "Notion is not connected" }, 503);
  }

  // Checked before any model call, so a forged handle costs nothing and trashes nothing.
  let pageIdToReplace: string | undefined;
  if (studyGuideRequest.revision !== undefined) {
    pageIdToReplace = await pageIdFromSignedHandle(notionAPIKey, studyGuideRequest.revision.pageHandle);
    if (pageIdToReplace === undefined) {
      return jsonResponse({ error: "revision.pageHandle was not issued by this Worker" }, 400);
    }
  }

  // Retries that name the broken rule, because a schema-valid guide still sometimes breaks a count or time rule
  // the schema cannot enforce, and the learner would lose a guide that was otherwise right.
  let lastValidationError = "";
  for (let attempt = 1; attempt <= maximumGuideAttempts; attempt += 1) {
    const anthropicReply = await requestAnthropicReplyJSON(environment.ANTHROPIC_API_KEY, "/study-guide", {
      model: "claude-sonnet-5-5",
      // Sonnet 5.5 thinks before it answers, and that thinking counts toward this limit.
      max_tokens: 16000,
      system: systemPrompt,
      // Sonnet 5.5 rejects a forced tool call, so the guide comes back as schema-checked JSON text.
      output_config: { format: { type: "json_schema", schema: guideOutputSchema } },
      messages: [userTurn(studyGuideRequest, lastValidationError)],
    });
    if (!anthropicReply.ok) {
      // The app treats every model failure as a 502, whatever status Anthropic sent. The body already names the cause.
      return jsonResponse(await anthropicReply.response.json(), 502);
    }

    const parsedGuide = parseStudyGuide(anthropicReply.replyJSON, studyGuideRequest.transcriptLines);
    if (!parsedGuide.ok) {
      lastValidationError = parsedGuide.error;
      console.error(`[/study-guide] attempt ${attempt} rejected: ${parsedGuide.error}`);
      continue;
    }
    const guide = parsedGuide.guide;

    const createdPage = await createNotionPage(
      notionAPIKey,
      guide.title,
      studyGuidePageBlocks(guide, studyGuideRequest.quizResults, studyGuideRequest.videoTitle, studyGuideRequest.videoURL),
    );
    if (!createdPage.ok) {
      return jsonResponse({ error: createdPage.error }, 502);
    }

    if (pageIdToReplace !== undefined) {
      const trashedPage = await trashNotionPage(notionAPIKey, pageIdToReplace);
      if (!trashedPage.ok) {
        console.error(`[/study-guide] could not trash the replaced page ${pageIdToReplace}: ${trashedPage.error}`);
      }
    }

    return jsonResponse(
      { pageHandle: await signedPageHandle(notionAPIKey, createdPage.reply.id), pageURL: createdPage.reply.url, guide },
      200,
    );
  }
  return jsonResponse({ error: lastValidationError }, 502);
}
