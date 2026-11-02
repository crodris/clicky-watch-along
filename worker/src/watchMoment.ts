/**
 * POST /watch-moment
 *
 * The app sends the last few minutes of a video's speech every few seconds. Haiku
 * decides whether a concrete fact was just finished, and if so writes one quiz
 * question about it. parseWatchMomentDecision is the only place the model reply is
 * trusted, so the pause rules that can be checked without a model live there.
 */

import { z } from "zod";

const watchMomentRequestSchema = z.object({
  transcript: z.string(),
  newTranscript: z.string(),
  alreadyAskedQuestions: z.array(z.string()),
  screenshotBase64: z.string(),
  screenshotMediaType: z.literal("image/jpeg"),
});

const noPauseSchema = z.object({ shouldPause: z.literal(false) });

const pauseSchema = z
  .object({
    shouldPause: z.literal(true),
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
    subject: z.string().trim().min(1),
  })
  .refine((pause) => !containsWholeWords(pause.question, pause.answerLabel), {
    message: "question must not contain the answer",
    path: ["question"],
  });

const watchMomentDecisionSchema = z.union([noPauseSchema, pauseSchema]);

const anthropicMessageSchema = z.object({
  content: z.array(
    z.object({
      type: z.string(),
      name: z.string().optional(),
      input: z.unknown().optional(),
    }),
  ),
});

export type WatchMomentResponse = z.infer<typeof watchMomentDecisionSchema>;
type WatchMomentRequest = z.infer<typeof watchMomentRequestSchema>;
type AnthropicMessage = z.infer<typeof anthropicMessageSchema>;

export type WatchMomentParseResult =
  | { ok: true; response: WatchMomentResponse }
  | { ok: false; error: string };

const maximumDecisionAttempts = 2;

const decideToolName = "decide_pause";

const decideToolInputSchema = {
  type: "object",
  properties: {
    shouldPause: {
      type: "boolean",
      description:
        "True only when a concrete, teachable fact or explanation was just finished at the end of the new transcript.",
    },
    question: {
      type: "string",
      description:
        "Only when shouldPause is true. A short cheerful opener such as \"Let's pause here!\", then a question about what was just explained. Does not contain the answer.",
    },
    answerLabel: {
      type: "string",
      description: "Only when shouldPause is true. One or two words the learner would say as the answer.",
    },
    functionWords: {
      type: "array",
      description:
        "Only when shouldPause is true. Lowercase single words that show the learner understood what the answer does or why.",
      items: { type: "string", pattern: "^[a-z]+$" },
    },
    explanation: {
      type: "string",
      description: "Only when shouldPause is true. One spoken sentence that names the answer and says why.",
    },
    subject: {
      type: "string",
      description:
        "Only when shouldPause is true. What a 3D model of this moment would show, such as \"great white shark liver\".",
    },
  },
  required: ["shouldPause"],
};

const systemPrompt = [
  "You watch a video with a learner by reading its transcript. You decide whether to pause the video and quiz the learner right now.",
  "Call decide_pause.",
  "",
  "Pause (shouldPause true) only when all of these hold:",
  "- The end of the new transcript finishes a concrete, teachable fact or explanation, such as what a body part is, what it does, or why something happens.",
  "- The speaker has stopped that thought. The last sentence of the new transcript is complete and the speaker is not still explaining the point.",
  "- The fact is stated in the transcript. Never ask about anything the transcript does not say, and never use outside knowledge to build the answer.",
  "",
  "Do not pause (shouldPause false) when any of these hold:",
  "- The new transcript ends mid-sentence, or mid-explanation with more of the point still to come.",
  "- The speech is an intro, a welcome, a trailer, or a preview of what the video will cover.",
  "- The speech is an ad, a sponsor read, a plug for a product or channel, or a request to like and subscribe.",
  "- The speech is casual talk, jokes, or transitions with no fact in them.",
  "- The fact is already covered by a question in the already asked list. Treat a question on the same topic as covered, even if it is worded differently.",
  "",
  "Pacing: the learner should get about one pause for every 60 to 90 seconds of content. Prefer waiting for a clearly complete fact over pausing early. When unsure, do not pause.",
  "",
  "When you pause:",
  "- Write for a curious learner. Ask what something is and what it does, or why it happens.",
  "- question opens with one short cheerful line, such as \"Let's pause here!\", then asks one thing about what was just explained. It must not contain the answer or hint at it.",
  "- answerLabel is the name of one thing, in one or two words the learner would say out loud, with no commas or lists. A longer name shrinks to its key word or two, such as \"Ampullae\" for \"ampullae of Lorenzini\". Never use three words or more.",
  "- functionWords are lowercase single words about what the answer does or why, such as \"floats\" or \"buoyancy\". Leave out filler words such as \"because\", \"so\", and \"instead\".",
  "- explanation is one spoken sentence that names the answer and says why.",
  "- subject is what a 3D model of the moment would show, such as \"great white shark liver\".",
  "",
  "The screenshot shows the video frame. Use it only to name the subject, never as a source of facts.",
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

export function parseWatchMomentDecision(toolInput: unknown): WatchMomentParseResult {
  const parsedDecision = watchMomentDecisionSchema.safeParse(toolInput);
  if (!parsedDecision.success) {
    const issueMessages = parsedDecision.error.issues.map((issue) => issue.message);
    return { ok: false, error: issueMessages.join("; ") };
  }
  return { ok: true, response: parsedDecision.data };
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function userTurn(watchMomentRequest: WatchMomentRequest, rejectedReplyError: string) {
  const alreadyAskedList =
    watchMomentRequest.alreadyAskedQuestions.length > 0
      ? watchMomentRequest.alreadyAskedQuestions.map((question) => `- ${question}`).join("\n")
      : "(none yet)";

  return {
    role: "user" as const,
    content: [
      {
        type: "image" as const,
        source: {
          type: "base64" as const,
          media_type: watchMomentRequest.screenshotMediaType,
          data: watchMomentRequest.screenshotBase64,
        },
      },
      {
        type: "text" as const,
        text: [
          "Already asked questions:",
          alreadyAskedList,
          "",
          "Transcript of the last few minutes:",
          watchMomentRequest.transcript,
          "",
          "New transcript since the last check. Decide based on how this ends:",
          watchMomentRequest.newTranscript,
          ...(rejectedReplyError.length > 0
            ? ["", `Your previous reply was rejected: ${rejectedReplyError}. Call decide_pause again and fix that.`]
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

export async function handleWatchMoment(request: Request, anthropicAPIKey: string): Promise<Response> {
  let requestJSON: unknown;
  try {
    requestJSON = await request.json();
  } catch {
    return jsonResponse({ error: "Request body must be JSON" }, 400);
  }

  const parsedRequest = watchMomentRequestSchema.safeParse(requestJSON);
  if (!parsedRequest.success) {
    return jsonResponse({ error: parsedRequest.error.message }, 400);
  }

  // One retry that names the broken rule, because a forced tool call still
  // sometimes breaks one the schema enforces, such as a three word answerLabel,
  // and the learner would lose a pause that was otherwise right.
  let lastValidationError = "";
  for (let attempt = 1; attempt <= maximumDecisionAttempts; attempt += 1) {
    const anthropicResponse = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": anthropicAPIKey,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: "claude-haiku-5-5",
        max_tokens: 1024,
        system: systemPrompt,
        tools: [
          {
            name: decideToolName,
            description: "Decide whether to pause the video now, and if so write the question.",
            input_schema: decideToolInputSchema,
          },
        ],
        tool_choice: { type: "tool", name: decideToolName, disable_parallel_tool_use: true },
        messages: [userTurn(parsedRequest.data, lastValidationError)],
      }),
    });

    if (!anthropicResponse.ok) {
      const errorText = await anthropicResponse.text();
      console.error(`[/watch-moment] Anthropic API error ${anthropicResponse.status}: ${errorText}`);
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

    const decision = parseWatchMomentDecision(toolInputNamed(parsedMessage.data, decideToolName));
    if (decision.ok) {
      return jsonResponse(decision.response, 200);
    }
    lastValidationError = decision.error;
  }
  return jsonResponse({ error: lastValidationError }, 502);
}
