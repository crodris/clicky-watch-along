// Clicky benchmark. Measures latency, tokens, and cost of every Worker route the demo uses,
// against a Worker started by the verify-clicky helper, and checks each reply on fixed fixtures.
//
//   .claude/skills/verify-clicky/verify-clicky.sh worker-up
//   node bench/bench.ts worker --label baseline [--runs 5] [--only chat-first,tts]
//   node bench/bench.ts app --label baseline [--runs 3]
//
// Results go to bench/results/<label>-<kind>-<sha>.json. See bench/README.md.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, realpathSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const benchDirectory = dirname(fileURLToPath(import.meta.url));
const checkoutRoot = dirname(benchDirectory);
const fixturesDirectory = join(benchDirectory, "fixtures");
const verifyClickyScript = join(checkoutRoot, ".claude/skills/verify-clicky/verify-clicky.sh");
const verifyClickyStateDirectory = join(checkoutRoot, ".verify-clicky");

// USD per million tokens, from https://platform.claude.com/docs/en/about-claude/pricing (fetched 2026-11-13).
const anthropicPricesPerMillionTokens: Record<string, { input: number; cacheWrite: number; cacheRead: number; output: number }> = {
  "claude-sonnet-4-6": { input: 3, cacheWrite: 3.75, cacheRead: 0.3, output: 15 },
  "claude-sonnet-5-5": { input: 2, cacheWrite: 2.5, cacheRead: 0.1, output: 10 },
  "claude-haiku-5-5": { input: 0.1, cacheWrite: 0.125, cacheRead: 0.01, output: 0.5 },
};
// OpenAI's pricing page refuses automated fetches, so a GPT scene uses the repo's measured estimate per call.
const gptLiveSceneCostPerCallUSD = 0.23;
// https://elevenlabs.io/pricing/api (fetched 2026-11-13): multilingual v2 costs $0.08 per 1,000 characters, Flash and Turbo $0.04.
const elevenLabsPricePerThousandCharacters: Record<string, number> = {
  eleven_v4: 0.08,
  eleven_v4_turbo: 0.04,
  eleven_multilingual_v2: 0.08,
  eleven_flash_v2_5: 0.04,
  eleven_turbo_v2_5: 0.04,
};

type UsageLine = {
  route: string;
  model: string;
  inputTokens: number;
  cacheWriteTokens: number;
  cacheReadTokens: number;
  outputTokens: number;
};

type QualityCheck = { passed: boolean; detail: string };

type Sample = {
  caseId: string;
  runIndex: number;
  httpStatus: number;
  firstByteMs: number;
  firstTokenMs: number | null;
  /** /tts only: when the app would start playing, which is the whole body for an MP3 and the first buffer for streamed PCM. */
  firstAudioMs: number | null;
  totalMs: number;
  usageLines: UsageLine[];
  ttsCharacters: number;
  /** Null when a model or speech model in the sample has no price. */
  costUSD: number | null;
  quality: QualityCheck;
  /** The start of a text reply, so a reviewer can read what changed. A live scene page is left out for size. */
  replyPreview: string;
};

type BenchCase = {
  id: string;
  route: string;
  description: string;
  requestBody: (appProfile: AppProfile) => unknown;
  /** The query the app adds to the route, if any. */
  requestQuery?: (appProfile: AppProfile) => string;
  checkReply: (replyText: string, contentType: string, replyBytes: number) => QualityCheck;
};

function numberField(record: Record<string, unknown>, key: string): number {
  const value = record[key];
  return typeof value === "number" ? value : 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseJSONObject(text: string): Record<string, unknown> | undefined {
  try {
    const parsed: unknown = JSON.parse(text);
    return isRecord(parsed) ? parsed : undefined;
  } catch {
    return undefined;
  }
}

/** Reads an Anthropic or OpenAI usage object, which name the cache and output fields differently. */
function usageLineFromUsageObject(route: string, usageObject: Record<string, unknown>): UsageLine {
  const inputTokensDetails = isRecord(usageObject.input_tokens_details) ? usageObject.input_tokens_details : {};
  return {
    route,
    model: typeof usageObject.model === "string" ? usageObject.model : "unknown",
    inputTokens: numberField(usageObject, "input_tokens"),
    cacheWriteTokens: numberField(usageObject, "cache_creation_input_tokens"),
    cacheReadTokens: numberField(usageObject, "cache_read_input_tokens") || numberField(inputTokensDetails, "cached_tokens"),
    outputTokens: numberField(usageObject, "output_tokens"),
  };
}

/** Null when the model has no price, so one unpriced reply cannot end a run that has already spent money. */
function costOfUsageLine(usageLine: UsageLine): number | null {
  if (usageLine.model.startsWith("gpt-")) {
    return gptLiveSceneCostPerCallUSD;
  }
  const prices = anthropicPricesPerMillionTokens[usageLine.model];
  if (prices === undefined) {
    console.warn(`No price for model ${usageLine.model}, so its cost is recorded as unknown. Add it to anthropicPricesPerMillionTokens.`);
    return null;
  }
  return (
    (usageLine.inputTokens * prices.input +
      usageLine.cacheWriteTokens * prices.cacheWrite +
      usageLine.cacheReadTokens * prices.cacheRead +
      usageLine.outputTokens * prices.output) /
    1_000_000
  );
}

// ---------- Fixtures ----------

const fixtureBase64 = (fileName: string) => readFileSync(join(fixturesDirectory, fileName)).toString("base64");

/**
 * What one checkout's app sends to the Worker, read from its Swift source. Two sides of a comparison
 * can run different app versions, so each side's requests mirror its own app, not this file's guesses.
 */
type AppProfile = {
  chatModel: string;
  chatEffort: string | undefined;
  /** Newer apps mark the system prompt's cache breakpoint themselves. */
  chatSystemPromptCached: boolean;
  chatSystemPrompt: string;
  ttsModel: string;
  /** Undefined means the app downloads a whole MP3 before it plays any of it. */
  ttsOutputFormat: string | undefined;
  /** Bytes of streamed audio the app collects before it starts playing. */
  ttsFirstBufferBytes: number;
};

function swiftSource(appCheckout: string, fileName: string): string {
  return readFileSync(join(appCheckout, "leanring-buddy", fileName), "utf8");
}

function requiredMatch(sourceText: string, pattern: RegExp, whatIsMissing: string): RegExpMatchArray {
  const sourceMatch = sourceText.match(pattern);
  if (sourceMatch === null) {
    throw new Error(`The benchmark could not read ${whatIsMissing} from the app source. Update readAppProfile.`);
  }
  return sourceMatch;
}

function readAppProfile(appCheckout: string): AppProfile {
  const claudeAPISource = swiftSource(appCheckout, "ClaudeAPI.swift");
  const companionManagerSource = swiftSource(appCheckout, "CompanionManager.swift");
  const ttsClientSource = swiftSource(appCheckout, "ElevenLabsTTSClient.swift");
  // Newer app versions name the default model in ClaudeVoiceModel, and older ones in CompanionManager's selectedModel.
  const chatModel =
    claudeAPISource.match(/sonnetModelID = "([^"]+)"/)?.[1] ??
    requiredMatch(companionManagerSource, /"selectedClaudeModel"\) \?\? "([^"]+)"/, "the default chat model")[1];
  // Everything before the unused non-streaming call holds the streamed body, in streamingRequestBody or inline in older apps.
  const streamingBodySource = claudeAPISource.slice(0, claudeAPISource.indexOf("func analyzeImage("));
  const chatEffort = streamingBodySource.match(/"output_config": \["effort": "(\w+)"\]/)?.[1];
  const samplesPerBuffer = ttsClientSource.match(/samplesPerBuffer = ([\d_]+)/)?.[1];
  return {
    chatModel,
    chatEffort,
    chatSystemPromptCached: /"cache_control": \["type": "ephemeral"\]/.test(streamingBodySource),
    chatSystemPrompt: appChatSystemPrompt(companionManagerSource),
    ttsModel: requiredMatch(ttsClientSource, /"model_id": "([^"]+)"/, "the TTS model")[1],
    ttsOutputFormat: ttsClientSource.match(/name: "output_format", value: "([^"]+)"/)?.[1],
    ttsFirstBufferBytes: samplesPerBuffer === undefined ? 0 : Number(samplesPerBuffer.replaceAll("_", "")) * 2,
  };
}

/** Reads the app's own chat system prompt, so the benchmark sends what the app sends even after the prompt changes. */
function appChatSystemPrompt(companionManagerSource: string): string {
  const promptMatch = companionManagerSource.match(
    /companionVoiceResponseSystemPrompt = """\n([\s\S]*?)\n( *)"""/,
  );
  if (promptMatch === null) {
    throw new Error("companionVoiceResponseSystemPrompt not found in CompanionManager.swift");
  }
  // Swift strips the closing delimiter's indentation from every line of a multiline string.
  const closingIndentation = promptMatch[2];
  return promptMatch[1]
    .split("\n")
    .map((promptLine) => (promptLine.startsWith(closingIndentation) ? promptLine.slice(closingIndentation.length) : promptLine))
    .join("\n");
}

/** The /chat body ClaudeAPI.analyzeImageStreaming builds for one screen. */
function appChatRequestBody(
  appProfile: AppProfile,
  transcript: string,
  conversationHistory: { userTranscript: string; assistantResponse: string }[],
) {
  const historyMessages = conversationHistory.flatMap((exchange) => [
    { role: "user", content: exchange.userTranscript },
    { role: "assistant", content: exchange.assistantResponse },
  ]);
  return {
    model: appProfile.chatModel,
    max_tokens: 1024,
    stream: true,
    ...(appProfile.chatEffort === undefined ? {} : { output_config: { effort: appProfile.chatEffort } }),
    system: appProfile.chatSystemPromptCached
      ? [{ type: "text", text: appProfile.chatSystemPrompt, cache_control: { type: "ephemeral" } }]
      : appProfile.chatSystemPrompt,
    messages: [
      ...historyMessages,
      {
        role: "user",
        content: [
          { type: "image", source: { type: "base64", media_type: "image/jpeg", data: fixtureBase64("screen.jpg") } },
          { type: "text", text: "user's screen (cursor is here) (image dimensions: 1280x800 pixels)" },
          { type: "text", text: transcript },
        ],
      },
    ],
  };
}

/** Reported with each reply, since a longer reply makes speech slower and costlier, but it does not fail the check. */
function spokenSentenceCount(replyText: string): number {
  const spokenText = replyText.replace(/\[POINT:[^\]]*\]/g, "").trim();
  return spokenText.split(/[.!?](?:\s|$)/).filter((sentence) => sentence.trim().length > 0).length;
}

/** The screen fixture draws "Download PDF" as a button at the top right and a sidebar link at the bottom left. */
function pointIsOnADownloadPDFControl(pointX: number, pointY: number): boolean {
  const topRightButton = pointX >= 1140 && pointX <= 1280 && pointY >= 38 && pointY <= 80;
  const sidebarLink = pointX >= 10 && pointX <= 140 && pointY >= 355 && pointY <= 388;
  return topRightButton || sidebarLink;
}

const spokenReplyForSpeech =
  "the heart has four chambers. the two atria on top collect blood, and the two ventricles underneath pump it out, the left one sending it to your whole body.";

type JudgeQuiz = { question: string; answerLabel: string; explanation: string; heardTranscript?: string };

const heartQuiz: JudgeQuiz = {
  question: "What is this part of the heart, and what does it do?",
  answerLabel: "left ventricle",
  explanation: "The left ventricle pumps oxygen-rich blood out to the body through the aorta.",
};

/** A video quiz sends the captions the learner heard, and an answer they support counts even when it differs from the explanation. */
const sharkVideoQuiz: JudgeQuiz = {
  question: "Let's pause here! What keeps a shark from sinking, and how?",
  answerLabel: "liver",
  explanation: "A shark's big liver is full of oil, which is lighter than water, so it helps the shark float.",
  heardTranscript:
    "Sharks have no swim bladder, the air sac most fish use to float. Instead a shark keeps swimming, and its fins act like the wings of a plane, giving it lift as it moves forward. Its liver is also huge and full of oil.",
};

function judgeCase(judgeCaseSpec: {
  caseSuffix: string;
  quiz: JudgeQuiz;
  learnerTranscript: string;
  expectedVerdict: string;
  /** A reply that grades a wrong or name-only answer must not give the answer away. */
  wordsTheReplyMustNotSay?: string[];
}): BenchCase {
  const { caseSuffix, quiz, learnerTranscript, expectedVerdict, wordsTheReplyMustNotSay = [] } = judgeCaseSpec;
  return {
    id: `judge-${caseSuffix}`,
    route: "/judge-answer",
    description: `Grades "${learnerTranscript}" and expects ${expectedVerdict}`,
    requestBody: () => ({ ...quiz, transcript: learnerTranscript }),
    checkReply: (replyText) => {
      const reply = parseJSONObject(replyText);
      const verdict = reply?.verdict;
      const spokenReply = String(reply?.spokenReply ?? "").toLowerCase();
      const giveaways = wordsTheReplyMustNotSay.filter((giveaway) => spokenReply.includes(giveaway));
      return {
        passed: verdict === expectedVerdict && giveaways.length === 0,
        detail: `verdict ${String(verdict)}${giveaways.length > 0 ? `, reply gives away ${giveaways.join(", ")}` : ""}`,
      };
    },
  };
}

function framePartsCase(
  id: string,
  frameFileName: string,
  expectWholePicture: boolean,
  expectShowsDepth: boolean,
  description: string,
): BenchCase {
  return {
    id,
    route: "/video-frame-parts",
    description,
    requestBody: () => ({
      frameBase64: fixtureBase64(frameFileName),
      frameWidth: 1280,
      frameHeight: 720,
      subject: "",
      question: "",
      answerLabel: "",
    }),
    checkReply: (replyText) => {
      const reply = parseJSONObject(replyText);
      if (reply?.subjectFound !== true) {
        return { passed: false, detail: "subjectFound is not true" };
      }
      const parts = Array.isArray(reply.parts) ? reply.parts : [];
      const wholePicture = reply.wholePictureIsSubject === true;
      const showsDepth = reply.pictureShowsDepth === true;
      const passed = wholePicture === expectWholePicture && showsDepth === expectShowsDepth && parts.length >= 3;
      return { passed, detail: `wholePictureIsSubject ${wholePicture}, pictureShowsDepth ${showsDepth}, ${parts.length} parts` };
    },
  };
}

const benchCases: BenchCase[] = [
  {
    id: "chat-first",
    route: "/chat",
    description: "First push-to-talk question with one 1280x800 screenshot, streamed",
    requestBody: (appProfile) => appChatRequestBody(appProfile, "how do i download this page as a pdf?", []),
    checkReply: (replyText) => {
      const pointMatch = replyText.match(/\[POINT:(\d+),(\d+)/);
      if (pointMatch === null) {
        return { passed: false, detail: "no [POINT:x,y] tag" };
      }
      const pointX = Number(pointMatch[1]);
      const pointY = Number(pointMatch[2]);
      const sentenceCount = spokenSentenceCount(replyText);
      return {
        passed: pointIsOnADownloadPDFControl(pointX, pointY),
        detail: `pointed at ${pointX},${pointY}, ${sentenceCount} sentences`,
      };
    },
  },
  {
    id: "chat-followup",
    route: "/chat",
    description: "Second question in the same conversation, with one exchange of history",
    requestBody: (appProfile) =>
      appChatRequestBody(appProfile, "what are the four chambers called?", [
        {
          userTranscript: "how do i download this page as a pdf?",
          assistantResponse: "see that blue download pdf button up in the top right? click that and it'll save the whole article for you.",
        },
      ]),
    checkReply: (replyText) => {
      const spokenText = replyText.toLowerCase();
      const namesTheChambers = spokenText.includes("atri") && spokenText.includes("ventricle") && /\[POINT:/.test(replyText);
      const sentenceCount = spokenSentenceCount(replyText);
      return {
        passed: namesTheChambers,
        detail: `${namesTheChambers ? "names atria and ventricles" : "misses a chamber name or the point tag"}, ${sentenceCount} sentences`,
      };
    },
  },
  {
    id: "tts",
    route: "/tts",
    description: `Speaks a ${spokenReplyForSpeech.length}-character reply with the app's ElevenLabs settings`,
    requestQuery: (appProfile) => (appProfile.ttsOutputFormat === undefined ? "" : `?output_format=${appProfile.ttsOutputFormat}`),
    requestBody: (appProfile) => ({
      text: spokenReplyForSpeech,
      model_id: appProfile.ttsModel,
      voice_settings: { stability: 0.35, similarity_boost: 0.75, style: 0.4 },
    }),
    checkReply: (_replyText, contentType, replyBytes) => ({
      passed: contentType.includes("audio") && replyBytes > 20_000,
      detail: `${contentType}, ${Math.round(replyBytes / 1024)} KB`,
    }),
  },
  {
    id: "video-quiz-plan",
    route: "/video-quiz-plan",
    description: "Plans quiz moments for the heart video transcript in verify-clicky's fixture",
    requestBody: () =>
      JSON.parse(readFileSync(join(checkoutRoot, ".claude/skills/verify-clicky/fixtures/video-quiz-plan.json"), "utf8")),
    checkReply: (replyText) => {
      const reply = parseJSONObject(replyText);
      const moments = Array.isArray(reply?.moments) ? reply.moments : [];
      return { passed: moments.length >= 1, detail: `${moments.length} moments` };
    },
  },
  {
    id: "video-quiz-plan-long",
    route: "/video-quiz-plan",
    description: "Plans quiz moments for a 10-minute shark video with a sponsor read and a subscribe request",
    requestBody: () => JSON.parse(readFileSync(join(fixturesDirectory, "video-quiz-plan-sharks.json"), "utf8")),
    checkReply: (replyText) => {
      const reply = parseJSONObject(replyText);
      const moments = (Array.isArray(reply?.moments) ? reply.moments : []).filter(isRecord);
      // The sponsor read is the lines at 216 and 228 seconds, and the subscribe request is the line at 576.
      const pauseTimes = moments.map((moment) => numberField(moment, "pauseAtSeconds"));
      const sourceTimes = moments.map((moment) => numberField(moment, "sourceLineSeconds"));
      const brokenRules = [
        ...pauseTimes.filter((pauseTime) => pauseTime > 216 && pauseTime <= 240).map((pauseTime) => `pause ${pauseTime} in the sponsor read`),
        ...sourceTimes.filter((sourceTime) => sourceTime === 216 || sourceTime === 228).map((sourceTime) => `asks about the sponsor line ${sourceTime}`),
        ...pauseTimes.filter((pauseTime) => pauseTime > 576).map((pauseTime) => `pause ${pauseTime} after the subscribe request`),
      ];
      return {
        passed: moments.length >= 2 && brokenRules.length === 0,
        detail: `${moments.length} moments at ${pauseTimes.join(", ")}${brokenRules.length > 0 ? `; ${brokenRules.join("; ")}` : ""}`,
      };
    },
  },
  framePartsCase("frame-parts-heart", "heart-diagram-frame.jpg", false, false, "Finds the heart in a 1280x720 diagram frame"),
  framePartsCase("frame-parts-painting", "starry-night-frame.jpg", true, false, "Lifts The Starry Night out as a whole picture"),
  framePartsCase("frame-parts-cutaway", "turbofan-cutaway-frame.jpg", false, true, "Marks a 3D cutaway of a turbofan as showing depth"),
  {
    id: "landmark",
    route: "/landmark",
    description: "Recognizes the Eiffel Tower in a 1280x720 frame",
    requestBody: () => ({
      frameBase64: fixtureBase64("eiffel-tower-frame.jpg"),
      videoTitle: "A day in Paris",
      learnerRequest: "show me this in 3D",
    }),
    checkReply: (replyText) => {
      const reply = parseJSONObject(replyText);
      if (reply?.isFamousPlace !== true) {
        return { passed: false, detail: "isFamousPlace is not true" };
      }
      const latitudeError = Math.abs(numberField(reply, "latitude") - 48.85826);
      const longitudeError = Math.abs(numberField(reply, "longitude") - 2.29451);
      const passed = String(reply.name).includes("Eiffel") && latitudeError < 0.003 && longitudeError < 0.003;
      return { passed, detail: `${String(reply.name)} at ${numberField(reply, "latitude")},${numberField(reply, "longitude")}` };
    },
  },
  {
    id: "live-scene",
    route: "/live-scene",
    description: "Builds a 3D scene for \"show me the inside of a heart\" over the screen fixture",
    requestBody: () => ({
      question: "show me the inside of a heart",
      screenshotBase64: fixtureBase64("screen.jpg"),
      screenshotMediaType: "image/jpeg",
    }),
    checkReply: (replyText) => {
      const reply = parseJSONObject(replyText);
      const quiz = isRecord(reply?.quiz) ? reply.quiz : {};
      const passed = typeof reply?.html === "string" && typeof quiz.answerLabel === "string";
      return { passed, detail: passed ? `answer ${String(quiz.answerLabel)}` : "no page or quiz" };
    },
  },
  judgeCase({ caseSuffix: "correct", quiz: heartQuiz, learnerTranscript: "that's the left ventricle, it pumps blood out to the whole body", expectedVerdict: "correct" }),
  judgeCase({ caseSuffix: "named-only", quiz: heartQuiz, learnerTranscript: "the left ventricle", expectedVerdict: "named_only", wordsTheReplyMustNotSay: ["pump", "aorta"] }),
  judgeCase({ caseSuffix: "wrong", quiz: heartQuiz, learnerTranscript: "is it the lungs?", expectedVerdict: "wrong", wordsTheReplyMustNotSay: ["ventricle", "pump"] }),
  judgeCase({ caseSuffix: "help", quiz: heartQuiz, learnerTranscript: "i don't know, can you tell me?", expectedVerdict: "asked_for_help" }),
  judgeCase({ caseSuffix: "function-only", quiz: heartQuiz, learnerTranscript: "it squeezes blood out to the rest of the body", expectedVerdict: "correct" }),
  judgeCase({ caseSuffix: "caption-supported", quiz: sharkVideoQuiz, learnerTranscript: "its fins give it lift like a plane wing while it swims", expectedVerdict: "correct" }),
  judgeCase({ caseSuffix: "caption-wrong", quiz: sharkVideoQuiz, learnerTranscript: "it has a swim bladder full of air", expectedVerdict: "wrong", wordsTheReplyMustNotSay: ["liver", "oil"] }),
];

// ---------- Worker runs ----------

function workerLogPath(workerCheckout: string, port: number): string {
  const logPathRecord = join(workerCheckout, ".verify-clicky", `worker-${port}.logpath`);
  if (!existsSync(logPathRecord)) {
    throw new Error(`No Worker started by verify-clicky in ${workerCheckout} on port ${port}. Run its verify-clicky.sh worker-up ${port}`);
  }
  return readFileSync(logPathRecord, "utf8").trim();
}

const ansiColorCode = new RegExp(String.fromCharCode(27) + "\\[[0-9;]*m", "g");

function usageLinesLoggedAfter(logPath: string, byteOffset: number): UsageLine[] {
  const newLogText = readFileSync(logPath).subarray(byteOffset).toString("utf8").replace(ansiColorCode, "");
  const usageLines: UsageLine[] = [];
  for (const usageMatch of newLogText.matchAll(/\[(\/[a-z-]+)\] usage (\{.*\})/g)) {
    const usageObject = parseJSONObject(usageMatch[2]);
    if (usageObject !== undefined) {
      usageLines.push(usageLineFromUsageObject(usageMatch[1], usageObject));
    }
  }
  return usageLines;
}

/** /chat streams Server-Sent Events and logs no usage line, so its usage and first text token come from the stream. */
async function readChatStream(response: Response, requestStartMs: number) {
  if (response.body === null) {
    throw new Error("/chat returned no body");
  }
  const decoder = new TextDecoder();
  let bufferedText = "";
  let replyText = "";
  let firstTokenMs: number | null = null;
  let usageObject: Record<string, unknown> = {};
  for await (const streamChunk of response.body) {
    bufferedText += decoder.decode(streamChunk, { stream: true });
    const completeLines = bufferedText.split("\n");
    bufferedText = completeLines.pop() ?? "";
    for (const streamLine of completeLines) {
      if (!streamLine.startsWith("data: ")) {
        continue;
      }
      const streamEvent = parseJSONObject(streamLine.slice(6));
      if (streamEvent === undefined) {
        continue;
      }
      if (streamEvent.type === "message_start" && isRecord(streamEvent.message)) {
        const startUsage = isRecord(streamEvent.message.usage) ? streamEvent.message.usage : {};
        usageObject = { ...startUsage, model: streamEvent.message.model };
      }
      if (streamEvent.type === "message_delta" && isRecord(streamEvent.usage)) {
        usageObject = { ...usageObject, output_tokens: streamEvent.usage.output_tokens };
      }
      if (streamEvent.type === "content_block_delta" && isRecord(streamEvent.delta) && streamEvent.delta.type === "text_delta") {
        firstTokenMs ??= performance.now() - requestStartMs;
        replyText += String(streamEvent.delta.text);
      }
    }
  }
  return { replyText, firstTokenMs, usageLine: usageLineFromUsageObject("/chat", usageObject) };
}

type BenchSide = { label: string; port: number; workerCheckout: string; logPath: string; appProfile: AppProfile; samples: Sample[] };

async function runOneSample(benchCase: BenchCase, runIndex: number, side: BenchSide): Promise<Sample> {
  const { port, logPath, appProfile } = side;
  const requestBodyText = JSON.stringify(benchCase.requestBody(appProfile));
  const logOffsetBeforeRequest = statSync(logPath).size;
  const requestStartMs = performance.now();
  const requestQuery = benchCase.requestQuery?.(appProfile) ?? "";
  const response = await fetch(`http://127.0.0.1:${port}${benchCase.route}${requestQuery}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: requestBodyText,
  });
  const firstByteMs = performance.now() - requestStartMs;
  const contentType = response.headers.get("content-type") ?? "";

  let replyText = "";
  let replyBytes = 0;
  let firstTokenMs: number | null = null;
  let firstAudioMs: number | null = null;
  let streamedUsageLines: UsageLine[] = [];
  if (benchCase.route === "/chat" && response.ok) {
    const chatStream = await readChatStream(response, requestStartMs);
    replyText = chatStream.replyText;
    firstTokenMs = chatStream.firstTokenMs;
    streamedUsageLines = [chatStream.usageLine];
  } else if (benchCase.route === "/tts" && response.ok && response.body !== null) {
    const audioIsStreamedPCM = contentType.includes("pcm");
    for await (const audioChunk of response.body) {
      replyBytes += audioChunk.length;
      if (audioIsStreamedPCM && firstAudioMs === null && replyBytes >= appProfile.ttsFirstBufferBytes) {
        firstAudioMs = performance.now() - requestStartMs;
      }
    }
    // An MP3 plays only once whole, and a PCM line shorter than one buffer plays when the stream ends.
    if (firstAudioMs === null) {
      firstAudioMs = performance.now() - requestStartMs;
    }
  } else {
    const replyBuffer = Buffer.from(await response.arrayBuffer());
    replyBytes = replyBuffer.length;
    replyText = contentType.includes("audio") ? "" : replyBuffer.toString("utf8");
  }
  const totalMs = performance.now() - requestStartMs;

  // The Worker writes its usage line just before it answers, so give wrangler's log a moment to flush.
  await new Promise((resolve) => setTimeout(resolve, 400));
  const usageLines = benchCase.route === "/chat" ? streamedUsageLines : usageLinesLoggedAfter(logPath, logOffsetBeforeRequest);

  let ttsCharacters = 0;
  const usageLineCosts = usageLines.map(costOfUsageLine);
  // A model route that answered but logged no usage line spent an unknown amount, which must not read as zero.
  const usageLineIsMissing = benchCase.route !== "/tts" && response.ok && usageLines.length === 0;
  if (usageLineIsMissing) {
    console.warn(`${benchCase.route} answered without a usage line, so its cost is recorded as unknown.`);
  }
  let costUSD = usageLineIsMissing || usageLineCosts.includes(null)
    ? null
    : usageLineCosts.reduce((runningCost: number, usageLineCost) => runningCost + (usageLineCost ?? 0), 0);
  if (benchCase.route === "/tts") {
    const ttsBody = parseJSONObject(requestBodyText) ?? {};
    ttsCharacters = String(ttsBody.text).length;
    const pricePerThousandCharacters = elevenLabsPricePerThousandCharacters[String(ttsBody.model_id)];
    if (pricePerThousandCharacters === undefined) {
      console.warn(`No price for speech model ${String(ttsBody.model_id)}, so its cost is recorded as unknown.`);
    }
    costUSD = pricePerThousandCharacters === undefined ? null : (ttsCharacters / 1000) * pricePerThousandCharacters;
  }

  const quality = response.ok
    ? benchCase.checkReply(replyText, contentType, replyBytes)
    : { passed: false, detail: `HTTP ${response.status}: ${replyText.slice(0, 200)}` };
  return {
    caseId: benchCase.id,
    runIndex,
    httpStatus: response.status,
    firstByteMs,
    firstTokenMs,
    firstAudioMs,
    totalMs,
    usageLines,
    ttsCharacters,
    costUSD,
    quality,
    replyPreview: benchCase.route === "/live-scene" ? "" : replyText.slice(0, 600),
  };
}

// ---------- App runs ----------

type AppStep = { id: string; transcript: string; doneLinePattern: RegExp; description: string };

const appSteps: AppStep[] = [
  {
    id: "app-voice-reply",
    transcript: "what are the four chambers of the heart called?",
    doneLinePattern: /^🔊 ElevenLabs TTS: playing/,
    description: "Transcript in to the first spoken word of the reply",
  },
  {
    id: "app-image-popout",
    transcript: "pop this out",
    doneLinePattern: /^Frame pop-out: lifting/,
    description: "\"pop this out\" over the heart image to the pop-out page starting",
  },
];

type AppSample = { stepId: string; runIndex: number; elapsedMs: number | null };

async function runAppBenchmark(runCount: number): Promise<AppSample[]> {
  // Each step's runs go together, because a finished pop-out stays up and sends the next question down another path.
  const rehearsalSteps = appSteps.flatMap((appStep) => Array.from({ length: runCount }, (_, runIndex) => ({ appStep, runIndex })));
  const rehearsalTranscripts = rehearsalSteps.map((rehearsalStep) => rehearsalStep.appStep.transcript);
  execFileSync(verifyClickyScript, ["app-launch", rehearsalTranscripts.join("|")], { stdio: "inherit" });
  const appLogPath = join(realpathSync(join(verifyClickyStateDirectory, "current")), "app.log");

  // Swift print() has no timestamps, so this watches the log and stamps each new line when it appears.
  const stampedLines: { atMs: number; text: string }[] = [];
  let readLineCount = 0;
  const deadlineMs = performance.now() + 15 * 60_000;
  while (performance.now() < deadlineMs) {
    const logLines = existsSync(appLogPath) ? readFileSync(appLogPath, "utf8").split("\n") : [];
    const nowMs = performance.now();
    for (const logLine of logLines.slice(readLineCount, Math.max(readLineCount, logLines.length - 1))) {
      stampedLines.push({ atMs: nowMs, text: logLine });
    }
    readLineCount = Math.max(readLineCount, logLines.length - 1);
    if (stampedLines.some((stampedLine) => stampedLine.text.startsWith("Live scene rehearsal: done"))) {
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  execFileSync(verifyClickyScript, ["app-quit"], { stdio: "inherit" });

  const appSamples: AppSample[] = [];
  const stepStartIndexes = stampedLines.flatMap((stampedLine, lineIndex) =>
    stampedLine.text.startsWith("Live scene rehearsal: saying") ? [lineIndex] : [],
  );
  stepStartIndexes.forEach((stepStartIndex, stepNumber) => {
    const { appStep, runIndex } = rehearsalSteps[stepNumber];
    const nextStepStartIndex = stepStartIndexes[stepNumber + 1] ?? stampedLines.length;
    const doneLine = stampedLines
      .slice(stepStartIndex, nextStepStartIndex)
      .find((stampedLine) => appStep.doneLinePattern.test(stampedLine.text));
    appSamples.push({
      stepId: appStep.id,
      runIndex,
      elapsedMs: doneLine === undefined ? null : doneLine.atMs - stampedLines[stepStartIndex].atMs,
    });
  });
  return appSamples;
}

// ---------- Summary ----------

function percentile(sortedValues: number[], fraction: number): number {
  if (sortedValues.length === 0) {
    return NaN;
  }
  const rank = Math.min(sortedValues.length - 1, Math.max(0, Math.ceil(fraction * sortedValues.length) - 1));
  return sortedValues[rank];
}

function latencySummary(values: number[]) {
  const sortedValues = [...values].sort((smaller, larger) => smaller - larger);
  return {
    p50: Math.round(percentile(sortedValues, 0.5)),
    p95: Math.round(percentile(sortedValues, 0.95)),
    min: Math.round(sortedValues[0] ?? NaN),
    max: Math.round(sortedValues[sortedValues.length - 1] ?? NaN),
  };
}

const mean = (values: number[]) => (values.length === 0 ? 0 : values.reduce((sum, value) => sum + value, 0) / values.length);

function summarizeCase(benchCase: BenchCase, samples: Sample[]) {
  const sumOverLines = (sample: Sample, pickTokens: (usageLine: UsageLine) => number) =>
    sample.usageLines.reduce((runningSum, usageLine) => runningSum + pickTokens(usageLine), 0);
  const firstTokenTimes = samples.flatMap((sample) => (sample.firstTokenMs === null ? [] : [sample.firstTokenMs]));
  const firstAudioTimes = samples.flatMap((sample) => (sample.firstAudioMs === null ? [] : [sample.firstAudioMs]));
  return {
    caseId: benchCase.id,
    route: benchCase.route,
    description: benchCase.description,
    models: [...new Set(samples.flatMap((sample) => sample.usageLines.map((usageLine) => usageLine.model)))],
    runs: samples.length,
    qualityPassed: samples.filter((sample) => sample.quality.passed).length,
    totalMs: latencySummary(samples.map((sample) => sample.totalMs)),
    firstByteMs: latencySummary(samples.map((sample) => sample.firstByteMs)),
    firstTokenMs: firstTokenTimes.length > 0 ? latencySummary(firstTokenTimes) : null,
    firstAudioMs: firstAudioTimes.length > 0 ? latencySummary(firstAudioTimes) : null,
    modelCallsPerRequest: mean(samples.map((sample) => sample.usageLines.length)),
    meanInputTokens: Math.round(mean(samples.map((sample) => sumOverLines(sample, (usageLine) => usageLine.inputTokens)))),
    meanCacheWriteTokens: Math.round(mean(samples.map((sample) => sumOverLines(sample, (usageLine) => usageLine.cacheWriteTokens)))),
    meanCacheReadTokens: Math.round(mean(samples.map((sample) => sumOverLines(sample, (usageLine) => usageLine.cacheReadTokens)))),
    meanOutputTokens: Math.round(mean(samples.map((sample) => sumOverLines(sample, (usageLine) => usageLine.outputTokens)))),
    // One unpriced sample makes the mean unknown, so an unknown cost never reads as zero.
    meanCostUSD: samples.some((sample) => sample.costUSD === null)
      ? null
      : Number(mean(samples.flatMap((sample) => (sample.costUSD === null ? [] : [sample.costUSD]))).toFixed(5)),
  };
}

// ---------- Command line ----------

function commandLineOption(optionName: string): string | undefined {
  const optionIndex = process.argv.indexOf(`--${optionName}`);
  return optionIndex === -1 ? undefined : process.argv[optionIndex + 1];
}

function writeResultFile(label: string, benchKind: string, measuredCheckout: string, result: unknown): string {
  const commitSHA = execFileSync("git", ["-C", measuredCheckout, "rev-parse", "--short=12", "HEAD"], { encoding: "utf8" }).trim();
  const workingTreeIsDirty =
    execFileSync("git", ["-C", measuredCheckout, "status", "--porcelain", "--", "worker", "leanring-buddy"], { encoding: "utf8" }).trim() !== "";
  const resultsDirectory = join(benchDirectory, "results");
  mkdirSync(resultsDirectory, { recursive: true });
  const resultPath = join(resultsDirectory, `${label}-${benchKind}-${commitSHA}.json`);
  const resultWithProvenance = { label, benchKind, commitSHA, workingTreeIsDirty, recordedAt: new Date().toISOString(), ...(isRecord(result) ? result : { result }) };
  writeFileSync(resultPath, `${JSON.stringify(resultWithProvenance, null, 2)}\n`);
  return resultPath;
}

async function main() {
  const benchKind = process.argv[2];
  const label = commandLineOption("label");
  if ((benchKind !== "worker" && benchKind !== "app") || label === undefined) {
    console.error("Usage: node bench/bench.ts worker|app --label <name> [--runs N] [--only caseId,...] [--port 8789] [--side label:port:checkout ...]");
    process.exit(1);
  }
  const runCount = Number(commandLineOption("runs") ?? (benchKind === "worker" ? 5 : 3));

  if (benchKind === "app") {
    const appSamples = await runAppBenchmark(runCount);
    const appSummary = appSteps.map((appStep) => {
      const stepTimes = appSamples.flatMap((appSample) => (appSample.stepId === appStep.id && appSample.elapsedMs !== null ? [appSample.elapsedMs] : []));
      return { stepId: appStep.id, description: appStep.description, runs: stepTimes.length, elapsedMs: latencySummary(stepTimes) };
    });
    console.table(appSummary.map((stepSummary) => ({ step: stepSummary.stepId, runs: stepSummary.runs, ...stepSummary.elapsedMs })));
    console.log(`saved ${writeResultFile(label, "app", checkoutRoot, { runCount, summary: appSummary, samples: appSamples })}`);
    return;
  }

  // Each --side is label:port:checkout. Two sides alternate request by request, so drift in upstream latency hits both.
  const sideSpecs = process.argv.flatMap((argument, argumentIndex) => (process.argv[argumentIndex - 1] === "--side" ? [argument] : []));
  const sides = (sideSpecs.length > 0 ? sideSpecs : [`${label}:${commandLineOption("port") ?? 8789}:${checkoutRoot}`]).map((sideSpec) => {
    const [sideLabel, sidePort, ...checkoutPathParts] = sideSpec.split(":");
    const workerCheckout = checkoutPathParts.join(":") || checkoutRoot;
    const side: BenchSide = {
      label: sideLabel,
      port: Number(sidePort),
      workerCheckout,
      logPath: workerLogPath(workerCheckout, Number(sidePort)),
      appProfile: readAppProfile(workerCheckout),
      samples: [],
    };
    console.log(`${side.label}: app profile ${JSON.stringify({ ...side.appProfile, chatSystemPrompt: `${side.appProfile.chatSystemPrompt.length} characters` })}`);
    return side;
  });
  const onlyCaseIds = commandLineOption("only")?.split(",");
  const selectedCases = benchCases.filter((benchCase) => onlyCaseIds === undefined || onlyCaseIds.includes(benchCase.id));
  for (const benchCase of selectedCases) {
    for (let runIndex = 0; runIndex < runCount; runIndex += 1) {
      for (const side of sides) {
        const sample = await runOneSample(benchCase, runIndex, side);
        side.samples.push(sample);
        console.log(
          `${side.label} ${benchCase.id} #${runIndex + 1}: HTTP ${sample.httpStatus}, ${Math.round(sample.totalMs)} ms` +
            `${sample.firstTokenMs === null ? "" : `, first token ${Math.round(sample.firstTokenMs)} ms`}, ` +
            `${sample.usageLines.length} model call(s), ${sample.costUSD === null ? "cost unknown" : `$${sample.costUSD.toFixed(4)}`}, ` +
            `${sample.quality.passed ? "PASS" : "FAIL"} ${sample.quality.detail}`,
        );
      }
    }
  }
  for (const side of sides) {
    const summary = selectedCases.map((benchCase) => summarizeCase(benchCase, side.samples.filter((sample) => sample.caseId === benchCase.id)));
    console.log(side.label);
    console.table(
      summary.map((caseSummary) => ({
        case: caseSummary.caseId,
        pass: `${caseSummary.qualityPassed}/${caseSummary.runs}`,
        p50: caseSummary.totalMs.p50,
        p95: caseSummary.totalMs.p95,
        ttft: caseSummary.firstTokenMs?.p50 ?? caseSummary.firstAudioMs?.p50 ?? "",
        in: caseSummary.meanInputTokens,
        cached: caseSummary.meanCacheReadTokens,
        out: caseSummary.meanOutputTokens,
        usd: caseSummary.meanCostUSD,
      })),
    );
    const interleavedWith = sides.filter((otherSide) => otherSide !== side).map((otherSide) => otherSide.label);
    console.log(`saved ${writeResultFile(side.label, "worker", side.workerCheckout, { runCount, port: side.port, interleavedWith, summary, samples: side.samples })}`);
  }
}

await main();
