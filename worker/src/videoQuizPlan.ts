/**
 * POST /video-quiz-plan
 *
 * The app sends a video's timestamped transcript once. Haiku picks three moments
 * to pause the video and writes a quiz question for each. parseVideoQuizPlan is
 * the only place the model reply is trusted, so every rule that can be checked
 * without a model lives there.
 */

import { z } from "zod";

const transcriptLineSchema = z.object({
  seconds: z.number().nonnegative(),
  text: z.string(),
});

const videoQuizPlanRequestSchema = z.object({
  title: z.string(),
  transcriptLines: z.array(transcriptLineSchema).min(1),
});

const videoQuizMomentSchema = z
  .object({
    pauseAtSeconds: z.number(),
    question: z.string().trim().min(1),
    answerLabel: z
      .string()
      .trim()
      .min(1)
      .refine((answerLabel) => answerLabel.split(/\s+/).length <= 2, {
        message: "answerLabel must be one or two words",
      }),
    functionWords: z.array(z.string().regex(/^[a-z]+$/)).min(1),
    explanation: z.string().trim().min(1),
    sourceLineSeconds: z.number(),
    subject: z.string().trim().min(1),
  });

const momentsPerPlan = 3;

const videoQuizPlanSchema = z.object({
  moments: z.array(videoQuizMomentSchema).length(momentsPerPlan),
});

const anthropicMessageSchema = z.object({
  content: z.array(
    z.object({
      type: z.string(),
      name: z.string().optional(),
      input: z.unknown().optional(),
    }),
  ),
});

export type TranscriptLine = z.infer<typeof transcriptLineSchema>;
export type VideoQuizMoment = z.infer<typeof videoQuizMomentSchema>;
export type VideoQuizPlan = z.infer<typeof videoQuizPlanSchema>;
type VideoQuizPlanRequest = z.infer<typeof videoQuizPlanRequestSchema>;
type AnthropicMessage = z.infer<typeof anthropicMessageSchema>;

export type VideoQuizPlanParseResult =
  | { ok: true; plan: VideoQuizPlan }
  | { ok: false; error: string };

export const minimumPauseAtSeconds = 20;
export const maximumFirstPauseAtSeconds = 60;
/** A fraction of the video's length, so a short video can still fit three moments. */
export const minimumGapBetweenMomentsAsFractionOfVideo = 0.1;

const maximumPlanAttempts = 3;

const planToolName = "plan_quiz_moments";

const planToolInputSchema = {
  type: "object",
  properties: {
    moments: {
      type: "array",
      minItems: momentsPerPlan,
      maxItems: momentsPerPlan,
      items: {
        type: "object",
        properties: {
          pauseAtSeconds: {
            type: "number",
            description:
              "The seconds value, copied exactly, of the transcript line that comes right after a concrete idea finishes. The video pauses when that line would start.",
          },
          sourceLineSeconds: {
            type: "number",
            description:
              "The seconds value of the transcript line that states the answer. It must be earlier than pauseAtSeconds.",
          },
          question: {
            type: "string",
            description:
              "A short cheerful opener such as \"Let's pause here!\", then a question about what was just explained. Does not contain the answer.",
          },
          answerLabel: {
            type: "string",
            description: "One or two words the learner would say as the answer.",
          },
          functionWords: {
            type: "array",
            description:
              "Lowercase single words that show the learner understood what the answer does or why.",
            items: { type: "string", pattern: "^[a-z]+$" },
          },
          explanation: {
            type: "string",
            description: "One spoken sentence that names the answer and says why.",
          },
          subject: {
            type: "string",
            description:
              "What a 3D model of this moment would show, such as \"great white shark liver\".",
          },
        },
        required: ["pauseAtSeconds", "sourceLineSeconds", "question", "answerLabel", "functionWords", "explanation", "subject"],
      },
    },
  },
  required: ["moments"],
};

const systemPrompt = [
  "You plan a quiz for a learner who is watching a video. You read the whole timestamped transcript once and pick the moments where the video will pause for a question.",
  "Call plan_quiz_moments with exactly 3 moments.",
  "",
  "Each transcript line starts with its time in seconds, like [123.4]. A line's idea ends where the next line begins.",
  "Pick each pauseAtSeconds by finding a concrete, teachable fact or explanation that finishes, then copying the seconds value of the line right after it, exactly as written.",
  "",
  "Rules for the three moments:",
  "- The transcript starts where the learner is. The first moment comes as early as a real fact allows, 20 to 45 seconds after the first line when the video has one there. Viewers should not wait long for the first question.",
  "- Spread the other two across the rest of the video. Keep them far apart.",
  `- None in the first ${minimumPauseAtSeconds} seconds, which are usually an intro or a hook.`,
  "- None during or after a sponsor read, an ad, a plug for a product or channel, or a request to like and subscribe.",
  "- Each fact must be stated in the transcript. Never ask about anything the transcript does not say, and never use outside knowledge.",
  "- Pause only after the speaker has finished the thought, never mid-explanation.",
  "- The learner has only heard lines before pauseAtSeconds. The line at pauseAtSeconds and every later line have not played yet, so the question, answer, and explanation must come only from earlier lines. sourceLineSeconds names the earlier line that states the answer.",
  "- Each moment covers a different fact.",
  "",
  "For each moment:",
  "- Write for a curious learner. Ask what something is and what it does, or why it happens.",
  "- question opens with one short cheerful line, such as \"Let's pause here!\", then asks one thing about what was just explained. It must not contain the answer or hint at it.",
  "- question is at most two sentences after the opener, short enough to say aloud.",
  "- answerLabel is the name of one thing, in one or two words the learner would say out loud, with no commas or lists. It is a noun naming a thing, such as a body part, a term, or a substance, never a quality like \"no leaking\". A longer name shrinks to its key word or two, such as \"Ampullae\" for \"ampullae of Lorenzini\". Never use three words or more.",
  "- functionWords are lowercase single words about what the answer does or why, such as \"floats\" or \"buoyancy\". Leave out filler words such as \"because\", \"so\", and \"instead\".",
  "- explanation is two short spoken sentences a 10-year-old can follow. It names the answer and says why it matters, using only what the transcript says.",
  "- subject is what a 3D model of the moment would show, such as \"great white shark liver\".",
].join("\n");

function containsWholeWords(text: string, phrase: string): boolean {
  const escapedPhrase = phrase
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9\s]/g, "")
    .split(/\s+/)
    .join("\\s+");
  if (escapedPhrase.length === 0) {
    return false;
  }
  const phrasePattern = new RegExp(`(^|[^a-z0-9])${escapedPhrase}($|[^a-z0-9])`);
  return phrasePattern.test(text.toLowerCase());
}

export function parseVideoQuizPlan(
  toolInput: unknown,
  transcriptLines: TranscriptLine[],
): VideoQuizPlanParseResult {
  const parsedPlan = videoQuizPlanSchema.safeParse(toolInput);
  if (!parsedPlan.success) {
    const issueMessages = parsedPlan.error.issues.map((issue) => {
      return issue.path.length > 0 ? `${issue.path.join(".")}: ${issue.message}` : issue.message;
    });
    return { ok: false, error: issueMessages.join("; ") };
  }

  // One give-away question should cost that stop, not the whole plan.
  const moments = parsedPlan.data.moments
    .filter((moment) => !containsWholeWords(moment.question, moment.answerLabel))
    .sort((earlierMoment, laterMoment) => {
      return earlierMoment.pauseAtSeconds - laterMoment.pauseAtSeconds;
    });
  if (moments.length === 0) {
    return { ok: false, error: "every question contains its own answer" };
  }

  const lineStartSeconds = new Set(transcriptLines.map((transcriptLine) => transcriptLine.seconds));
  // The app sends only what is left to watch, so timing rules count from the first line.
  const watchStartSeconds = Math.min(...transcriptLines.map((transcriptLine) => transcriptLine.seconds));
  for (const moment of moments) {
    if (!lineStartSeconds.has(moment.pauseAtSeconds)) {
      return {
        ok: false,
        error: `pauseAtSeconds ${moment.pauseAtSeconds} is not the seconds value of any transcript line`,
      };
    }
    if (!lineStartSeconds.has(moment.sourceLineSeconds) || moment.sourceLineSeconds >= moment.pauseAtSeconds) {
      return {
        ok: false,
        error: `sourceLineSeconds ${moment.sourceLineSeconds} must be a transcript line before pauseAtSeconds ${moment.pauseAtSeconds}, because the learner has not heard later lines`,
      };
    }
    if (moment.pauseAtSeconds - watchStartSeconds < minimumPauseAtSeconds) {
      return {
        ok: false,
        error: `pauseAtSeconds ${moment.pauseAtSeconds} is inside the first ${minimumPauseAtSeconds} seconds after the first transcript line`,
      };
    }
  }

  const firstPauseAtSeconds = Math.min(...moments.map((moment) => moment.pauseAtSeconds));
  if (firstPauseAtSeconds - watchStartSeconds > maximumFirstPauseAtSeconds) {
    return {
      ok: false,
      error: `The first pause at ${firstPauseAtSeconds} is more than ${maximumFirstPauseAtSeconds} seconds after the first transcript line`,
    };
  }

  const videoLengthSeconds = Math.max(...transcriptLines.map((transcriptLine) => transcriptLine.seconds));
  const minimumGapSeconds =
    (videoLengthSeconds - watchStartSeconds) * minimumGapBetweenMomentsAsFractionOfVideo;
  for (let momentIndex = 1; momentIndex < moments.length; momentIndex += 1) {
    const gapSeconds = moments[momentIndex].pauseAtSeconds - moments[momentIndex - 1].pauseAtSeconds;
    if (gapSeconds < minimumGapSeconds) {
      return {
        ok: false,
        error: `moments at ${moments[momentIndex - 1].pauseAtSeconds} and ${moments[momentIndex].pauseAtSeconds} are too close together, spread them across the video`,
      };
    }
  }

  return { ok: true, plan: { moments } };
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function userTurn(videoQuizPlanRequest: VideoQuizPlanRequest, rejectedReplyError: string) {
  const transcriptText = videoQuizPlanRequest.transcriptLines
    .map((transcriptLine) => `[${transcriptLine.seconds}] ${transcriptLine.text}`)
    .join("\n");

  return {
    role: "user" as const,
    content: [
      {
        type: "text" as const,
        text: [
          `Video title: ${videoQuizPlanRequest.title}`,
          "",
          "Transcript:",
          transcriptText,
          ...(rejectedReplyError.length > 0
            ? ["", `Your previous reply was rejected: ${rejectedReplyError}. Call plan_quiz_moments again and fix that.`]
            : []),
        ].join("\n"),
      },
    ],
  };
}

function toolInputNamed(message: AnthropicMessage, toolName: string): unknown {
  const toolUseBlock = message.content.find((contentBlock) => {
    return contentBlock.type === "tool_use" && contentBlock.name === toolName;
  });
  return toolUseBlock?.input;
}

export async function handleVideoQuizPlan(request: Request, anthropicAPIKey: string): Promise<Response> {
  let requestJSON: unknown;
  try {
    requestJSON = await request.json();
  } catch {
    return jsonResponse({ error: "Request body must be JSON" }, 400);
  }

  const parsedRequest = videoQuizPlanRequestSchema.safeParse(requestJSON);
  if (!parsedRequest.success) {
    return jsonResponse({ error: parsedRequest.error.message }, 400);
  }

  // Retries that name the broken rule, because a forced tool call still
  // sometimes breaks one the schema cannot enforce, such as a pause that is not
  // on a line boundary, and the learner would lose a plan that was otherwise right.
  let lastValidationError = "";
  for (let attempt = 1; attempt <= maximumPlanAttempts; attempt += 1) {
    const anthropicResponse = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": anthropicAPIKey,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: "claude-haiku-5-5",
        max_tokens: 2048,
        system: systemPrompt,
        tools: [
          {
            name: planToolName,
            description: "Plan the three moments where the video pauses for a quiz question.",
            input_schema: planToolInputSchema,
          },
        ],
        tool_choice: { type: "tool", name: planToolName, disable_parallel_tool_use: true },
        messages: [userTurn(parsedRequest.data, lastValidationError)],
      }),
    });

    if (!anthropicResponse.ok) {
      const errorText = await anthropicResponse.text();
      console.error(`[/video-quiz-plan] Anthropic API error ${anthropicResponse.status}: ${errorText}`);
      return jsonResponse(
        { error: errorText.length > 0 ? errorText : "Anthropic request failed" },
        anthropicResponse.status,
      );
    }

    let anthropicJSON: unknown;
    try {
      anthropicJSON = await anthropicResponse.json();
    } catch {
      return jsonResponse({ error: "Anthropic returned a body that was not JSON" }, 502);
    }

    const parsedMessage = anthropicMessageSchema.safeParse(anthropicJSON);
    if (!parsedMessage.success) {
      return jsonResponse({ error: "Anthropic response was missing tool content" }, 502);
    }

    const parsedPlan = parseVideoQuizPlan(
      toolInputNamed(parsedMessage.data, planToolName),
      parsedRequest.data.transcriptLines,
    );
    if (parsedPlan.ok) {
      return jsonResponse(parsedPlan.plan, 200);
    }
    lastValidationError = parsedPlan.error;
  }
  return jsonResponse({ error: lastValidationError }, 502);
}
