/**
 * POST /video-quiz-plan
 *
 * The app sends a video's timestamped transcript once. Sonnet decides how many
 * moments the video is worth pausing for, picks them, and writes a quiz question
 * for each. parseVideoQuizPlan is
 * the only place the model reply is trusted, so every rule that can be checked
 * without a model lives there.
 */

import { z } from "zod";
import { jsonResponse, parseJSONRequest, requestAnthropicReplyJSON } from "./anthropic";

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
    // A capital letter or a phrase is a formatting slip, so normalize it instead of spending a retry.
    // Phrases stay whole, because LiveSceneAnswerJudge splits one into words and needs all of them.
    functionWords: z
      .array(z.string().trim().toLowerCase())
      .transform((functionWords) => functionWords.filter((functionWord) => /[\p{L}\p{N}]/u.test(functionWord)))
      .pipe(z.array(z.string()).min(1)),
    explanation: z.string().trim().min(1),
    sourceLineSeconds: z.number(),
    subject: z.string().trim().min(1),
  });

const videoQuizPlanSchema = z.object({
  moments: z.array(videoQuizMomentSchema).min(1),
});

type TranscriptLine = z.infer<typeof transcriptLineSchema>;
type VideoQuizPlan = z.infer<typeof videoQuizPlanSchema>;
type VideoQuizPlanRequest = z.infer<typeof videoQuizPlanRequestSchema>;

type VideoQuizPlanParseResult =
  | { ok: true; plan: VideoQuizPlan }
  | { ok: false; error: string };

const minimumPauseAtSeconds = 20;
const maximumFirstPauseAtSeconds = 60;
/** A fraction of the video's length, so moments stay spread out and a plan holds at most about 10. */
const minimumGapBetweenMomentsAsFractionOfVideo = 0.1;

const maximumPlanAttempts = 3;

/** Structured output schema. Count and word rules stay in parseVideoQuizPlan, which names the broken rule on a retry. */
const planOutputSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    moments: {
      type: "array",
      items: {
        additionalProperties: false,
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
            items: { type: "string" },
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
  "Reply with the plan as JSON. You decide how many moments the video is worth: one for each distinct, teachable idea a learner should remember, usually one every 2 to 4 minutes. A short video may need only 1 or 2, and a long one may need more.",
  "",
  "Each transcript line starts with its time in seconds, like [123.4]. A line's idea ends where the next line begins.",
  "Pick each pauseAtSeconds by finding a concrete, teachable fact or explanation that finishes, then copying the seconds value of the line right after it, exactly as written.",
  "",
  "Rules for the moments:",
  "- The transcript starts where the learner is. The first moment comes as early as a real fact allows, 20 to 45 seconds after the first line when the video has one there. Viewers should not wait long for the first question.",
  "- Spread the rest across the video, at least a tenth of the remaining video apart, so the learner gets long stretches of watching between questions.",
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
    .replace(/[^\p{L}\p{N}\s]/gu, "")
    .split(/\s+/)
    .join("\\s+");
  if (escapedPhrase.length === 0) {
    return false;
  }
  // Unicode letters and digits, so an answer such as "résumé" still counts as a whole word in its question.
  const phrasePattern = new RegExp(`(^|[^\\p{L}\\p{N}])${escapedPhrase}($|[^\\p{L}\\p{N}])`, "u");
  return phrasePattern.test(text.toLowerCase());
}

/**
 * A pause between two line starts would stop the video mid-line, so it moves to where the line it falls in has finished.
 * A pause after the last line start keeps its time, so parseVideoQuizPlan rejects a time no line confirms.
 */
function lineStartAtOrAfter(secondsToSnap: number, lineStartsInOrder: number[]): number {
  return lineStartsInOrder.find((lineStart) => lineStart >= secondsToSnap) ?? secondsToSnap;
}

/**
 * A source time between two line starts names the line that was playing then, which started before it.
 * A source time before the first line keeps its time, so parseVideoQuizPlan rejects a line the model never saw.
 */
function lineStartAtOrBefore(secondsToSnap: number, lineStartsInOrder: number[]): number {
  return [...lineStartsInOrder].reverse().find((lineStart) => lineStart <= secondsToSnap) ?? secondsToSnap;
}

export function parseVideoQuizPlan(
  planJSON: unknown,
  transcriptLines: TranscriptLine[],
): VideoQuizPlanParseResult {
  const parsedPlan = videoQuizPlanSchema.safeParse(planJSON);
  if (!parsedPlan.success) {
    const issueMessages = parsedPlan.error.issues.map((issue) => {
      return issue.path.length > 0 ? `${issue.path.join(".")}: ${issue.message}` : issue.message;
    });
    return { ok: false, error: issueMessages.join("; ") };
  }

  const lineStartsInOrder = [...new Set(transcriptLines.map((transcriptLine) => transcriptLine.seconds))].sort(
    (earlierSeconds, laterSeconds) => earlierSeconds - laterSeconds,
  );

  // One give-away question should cost that stop, not the whole plan.
  const moments = parsedPlan.data.moments
    .map((moment) => ({
      ...moment,
      pauseAtSeconds: lineStartAtOrAfter(moment.pauseAtSeconds, lineStartsInOrder),
      sourceLineSeconds: lineStartAtOrBefore(moment.sourceLineSeconds, lineStartsInOrder),
    }))
    .filter((moment) => !containsWholeWords(moment.question, moment.answerLabel))
    .sort((earlierMoment, laterMoment) => {
      return earlierMoment.pauseAtSeconds - laterMoment.pauseAtSeconds;
    });
  if (moments.length === 0) {
    return { ok: false, error: "every question contains its own answer" };
  }

  // The app sends only what is left to watch, so timing rules count from the first line.
  const watchStartSeconds = Math.min(...transcriptLines.map((transcriptLine) => transcriptLine.seconds));
  const videoLengthSeconds = Math.max(...transcriptLines.map((transcriptLine) => transcriptLine.seconds));
  for (const moment of moments) {
    if (moment.pauseAtSeconds > videoLengthSeconds) {
      return {
        ok: false,
        error: `pauseAtSeconds ${moment.pauseAtSeconds} is after the last transcript line at ${videoLengthSeconds}`,
      };
    }
    if (moment.sourceLineSeconds < watchStartSeconds) {
      return {
        ok: false,
        error: `sourceLineSeconds ${moment.sourceLineSeconds} is before the first transcript line at ${watchStartSeconds}`,
      };
    }
    if (moment.sourceLineSeconds >= moment.pauseAtSeconds) {
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

function userTurn(videoQuizPlanRequest: VideoQuizPlanRequest, rejectedReplyError: string) {
  const transcriptText = videoQuizPlanRequest.transcriptLines
    .map((transcriptLine) => `[${transcriptLine.seconds}] ${transcriptLine.text}`)
    .join("\n");

  return {
    role: "user" as const,
    content: [
      {
        type: "text" as const,
        text: [`Video title: ${videoQuizPlanRequest.title}`, "", "Transcript:", transcriptText].join("\n"),
        // A retry sends the same system prompt and transcript, so it reads them from the cache instead of paying full price.
        cache_control: { type: "ephemeral" as const },
      },
      ...(rejectedReplyError.length > 0
        ? [
            {
              type: "text" as const,
              text: `Your previous reply was rejected: ${rejectedReplyError}. Reply with the plan again and fix that.`,
            },
          ]
        : []),
    ],
  };
}

export async function handleVideoQuizPlan(request: Request, anthropicAPIKey: string): Promise<Response> {
  const parsedRequest = await parseJSONRequest(request, videoQuizPlanRequestSchema);
  if (!parsedRequest.ok) {
    return parsedRequest.response;
  }
  const videoQuizPlanRequest = parsedRequest.requestBody;

  // Retries that name the broken rule, because a schema-valid plan still
  // sometimes breaks one the schema cannot enforce, such as a first pause past
  // the first minute, and the learner would lose a plan that was otherwise right.
  let lastValidationError = "";
  for (let attempt = 1; attempt <= maximumPlanAttempts; attempt += 1) {
    const anthropicReply = await requestAnthropicReplyJSON(anthropicAPIKey, "/video-quiz-plan", {
      model: "claude-sonnet-5-5",
      // Sonnet 5.5 thinks before it answers, and that thinking counts toward this limit.
      max_tokens: 16000,
      system: systemPrompt,
      // Sonnet 5.5 rejects a forced tool call, so the plan comes back as schema-checked JSON text.
      output_config: { format: { type: "json_schema", schema: planOutputSchema } },
      messages: [userTurn(videoQuizPlanRequest, lastValidationError)],
    });
    if (!anthropicReply.ok) {
      return anthropicReply.response;
    }

    const parsedPlan = parseVideoQuizPlan(anthropicReply.replyJSON, videoQuizPlanRequest.transcriptLines);
    if (parsedPlan.ok) {
      return jsonResponse(parsedPlan.plan, 200);
    }
    lastValidationError = parsedPlan.error;
    console.error(`[/video-quiz-plan] attempt ${attempt} rejected: ${parsedPlan.error}`);
  }
  return jsonResponse({ error: lastValidationError }, 502);
}
