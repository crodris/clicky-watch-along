// Blind pairwise judge for the bakeoff routes a pass or fail check cannot score: frame parts, picture flows, the quiz
// plan, and chat. It reads the replies `bench.ts worker --pages-dir <dir>` saved, pairs the baseline's reply with each
// challenger's, draws each reply over its frame in headless Chrome, and asks two judging models, one per vendor, which
// reply is better, with the replies in both A/B orders. A pair counts for a side only when a judge picks it both ways.
//
//   node bench/judge.ts --replies bench/replies [--routes /video-frame-parts,/picture-flows,/video-quiz-plan,/chat]
//     [--judges opus,sol] [--baseline base] [--pairs-per-case 1] [--effort medium] [--spot-checks 10] [--dry-run]
//
// --dry-run draws the replies and writes the spot-check page without calling a model, so it costs nothing.
// Judgments are saved after every call, so a run that stops can be run again and picks up where it stopped.
// The judging models' keys come from worker/.dev.vars and are never printed. See bench/README.md.

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { judgeModels, parseDevVars, requestJudgeVerdict, type JudgeKeys } from "./judgeModels.ts";
import {
  buildPairs,
  pickSpotChecks,
  presentationsOf,
  stableHash,
  summarizeJudgments,
  type Judgment,
  type PairOrder,
  type ReplyPair,
} from "./judgePairs.ts";
import {
  contextFromRequest,
  describeReply,
  judgedRoutes,
  judgePromptParts,
  overlayPage,
  spotCheckPage,
  type JudgeContext,
  type SpotCheckCard,
} from "./judgeRender.ts";
import { requestFileName, parseSavedReply, type SavedReply } from "./replyFiles.ts";
import { costOfUsageLine } from "./usage.ts";

const benchDirectory = dirname(fileURLToPath(import.meta.url));
const checkoutRoot = dirname(benchDirectory);

function commandLineOption(optionName: string): string | undefined {
  const optionIndex = process.argv.indexOf(`--${optionName}`);
  return optionIndex === -1 ? undefined : process.argv[optionIndex + 1];
}

/** An id that says nothing about which side or model made the reply, for file names a reader could see. */
function replyImageId(reply: SavedReply): string {
  return createHash("sha1").update(`${reply.side}|${reply.caseId}|${reply.runIndex}`).digest("hex").slice(0, 12);
}

function readSavedReplies(repliesDirectory: string): SavedReply[] {
  return readdirSync(repliesDirectory)
    .filter((fileName) => fileName.endsWith(".json"))
    .flatMap((fileName) => {
      const savedReply = parseSavedReply(JSON.parse(readFileSync(join(repliesDirectory, fileName), "utf8")));
      return savedReply === undefined ? [] : [savedReply];
    });
}

function renderOverlayToPNG(html: string, width: number, height: number, pngPath: string, scratchDirectory: string) {
  const chromePath = process.env.CHROME_PATH ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  const htmlPath = `${pngPath}.html`;
  writeFileSync(htmlPath, html);
  // A profile of its own, so a running Chrome never takes the launch over.
  execFileSync(
    chromePath,
    [
      "--headless=new",
      "--disable-gpu",
      "--hide-scrollbars",
      `--user-data-dir=${join(scratchDirectory, "chrome-profile")}`,
      `--window-size=${width},${height}`,
      `--screenshot=${pngPath}`,
      `file://${htmlPath}`,
    ],
    { stdio: "ignore", timeout: 60_000 },
  );
  rmSync(htmlPath);
}

async function runWithConcurrency<Item>(items: Item[], concurrency: number, work: (item: Item) => Promise<void>) {
  let nextIndex = 0;
  await Promise.all(
    Array.from({ length: Math.min(concurrency, items.length) }, async () => {
      while (nextIndex < items.length) {
        const item = items[nextIndex];
        nextIndex += 1;
        await work(item);
      }
    }),
  );
}

function requestSummary(context: JudgeContext): string {
  switch (context.kind) {
    case "frameParts":
      return "Find the subject of this frame and label its parts.";
    case "pictureFlows":
      return `Draw what flows through this picture. Its parts: ${context.partLabels.join(", ")}.`;
    case "quizPlan":
      return `Plan quiz moments for the video "${context.title}".`;
    case "chat":
      return `The user said: ${context.question}`;
  }
}

async function main() {
  const repliesDirectory = commandLineOption("replies") ?? join(benchDirectory, "replies");
  const outDirectory = commandLineOption("out") ?? join(repliesDirectory, "judged");
  const judgeNames = (commandLineOption("judges") ?? "opus,sol").split(",");
  const routes = commandLineOption("routes")?.split(",") ?? judgedRoutes;
  const effort = commandLineOption("effort") ?? "medium";
  const dryRun = process.argv.includes("--dry-run");
  const unknownJudge = judgeNames.find((judgeName) => judgeModels[judgeName] === undefined);
  if (unknownJudge !== undefined || !existsSync(repliesDirectory)) {
    console.error(
      unknownJudge !== undefined
        ? `Unknown judge ${unknownJudge}. Choose from ${Object.keys(judgeModels).join(", ")}.`
        : `No replies folder at ${repliesDirectory}. Run bench.ts worker with --pages-dir first.`,
    );
    process.exit(1);
  }

  const { pairs: allPairs, unusablePairCount } = buildPairs(readSavedReplies(repliesDirectory), {
    baselineName: commandLineOption("baseline") ?? "base",
    pairsPerCase: Number(commandLineOption("pairs-per-case") ?? 1),
    routes,
  });
  const contextByCaseId = new Map<string, JudgeContext>();
  for (const pair of allPairs) {
    const requestPath = join(repliesDirectory, requestFileName(pair.caseId));
    if (!contextByCaseId.has(pair.caseId) && existsSync(requestPath)) {
      const context = contextFromRequest(pair.route, JSON.parse(readFileSync(requestPath, "utf8")));
      if (context !== undefined) {
        contextByCaseId.set(pair.caseId, context);
      }
    }
  }
  const pairs = allPairs.filter((pair) => contextByCaseId.has(pair.caseId));
  const callCount = pairs.length * judgeNames.length * 2;
  console.log(
    `${pairs.length} pairs to judge (${unusablePairCount} left out because a reply failed, ${allPairs.length - pairs.length} because the case's request was not saved), ` +
      `${callCount} judging calls with ${judgeNames.join(" and ")}`,
  );
  if (pairs.length === 0) {
    console.error("Nothing to judge. Check --routes and that the replies have a baseline side named base, such as parts-base.");
    process.exit(1);
  }

  mkdirSync(join(outDirectory, "images"), { recursive: true });
  const overlayImages = new Map<string, string | undefined>();
  const repliesToDraw = new Map<string, { reply: SavedReply; context: JudgeContext }>();
  for (const pair of pairs) {
    for (const reply of [pair.baseline, pair.challenger]) {
      repliesToDraw.set(replyImageId(reply), { reply, context: contextByCaseId.get(pair.caseId) as JudgeContext });
    }
  }
  for (const [imageId, { reply, context }] of repliesToDraw) {
    const page = overlayPage(context, reply.replyText);
    if (page === undefined) {
      overlayImages.set(imageId, undefined);
      continue;
    }
    const pngPath = join(outDirectory, "images", `${imageId}.png`);
    if (!existsSync(pngPath)) {
      renderOverlayToPNG(page.html, page.width, page.height, pngPath, outDirectory);
    }
    overlayImages.set(imageId, imageId);
  }
  console.log(`drew ${[...overlayImages.values()].filter((imageId) => imageId !== undefined).length} replies over their frames in ${join(outDirectory, "images")}`);

  const judgmentsPath = join(outDirectory, "judgments.json");
  const judgments: Judgment[] = existsSync(judgmentsPath) ? JSON.parse(readFileSync(judgmentsPath, "utf8")) : [];

  if (!dryRun) {
    const devVars = parseDevVars(readFileSync(join(checkoutRoot, "worker", ".dev.vars"), "utf8"));
    const keys: JudgeKeys = { anthropicAPIKey: devVars.ANTHROPIC_API_KEY, openAIAPIKey: devVars.OPENAI_API_KEY };
    const missingKey = judgeNames.find((judgeName) => (judgeModels[judgeName].provider === "anthropic" ? keys.anthropicAPIKey : keys.openAIAPIKey) === undefined);
    if (missingKey !== undefined) {
      console.error(`worker/.dev.vars has no key for the ${missingKey} judge.`);
      process.exit(1);
    }

    const alreadyJudged = new Set(judgments.map((judgment) => `${judgment.pairId}|${judgment.judge}|${judgment.order}`));
    const calls = pairs.flatMap((pair) =>
      presentationsOf(pair).flatMap((presentation) =>
        judgeNames.map((judgeName) => ({ pair, presentation, judgeName })),
      ),
    ).filter(({ pair, presentation, judgeName }) => !alreadyJudged.has(`${pair.pairId}|${judgeName}|${presentation.order}`));
    console.log(`${calls.length} calls left (${callCount - calls.length} already saved)`);

    let spentUSD = 0;
    let failedCallCount = 0;
    await runWithConcurrency(calls, Number(commandLineOption("concurrency") ?? 4), async ({ pair, presentation, judgeName }) => {
      const context = contextByCaseId.get(pair.caseId) as JudgeContext;
      const judgedReply = (reply: SavedReply) => {
        const imageId = replyImageId(reply);
        const pngPath = overlayImages.get(imageId) === undefined ? undefined : join(outDirectory, "images", `${imageId}.png`);
        return { description: describeReply(context, reply.replyText), overlayPNGBase64: pngPath === undefined ? undefined : readFileSync(pngPath).toString("base64") };
      };
      const result = await requestJudgeVerdict(judgeModels[judgeName], judgePromptParts(context, judgedReply(presentation.a), judgedReply(presentation.b)), { keys, effort });
      if (!result.ok) {
        failedCallCount += 1;
        console.error(`${pair.caseId} ${judgeName} order ${presentation.order} failed: ${result.error}`);
        return;
      }
      spentUSD += costOfUsageLine(result.usage) ?? 0;
      judgments.push({ pairId: pair.pairId, judge: judgeName, order: presentation.order, verdict: result.winner, reason: result.reason });
      writeFileSync(judgmentsPath, `${JSON.stringify(judgments, null, 2)}\n`);
    });
    console.log(`judging spent about $${spentUSD.toFixed(2)} by the price tables in usage.ts${failedCallCount > 0 ? `, and ${failedCallCount} calls failed, so run it again to retry them` : ""}`);
  }

  const summaries = summarizeJudgments(pairs, judgments, judgeNames);
  console.table(
    summaries.map((summary) => ({
      route: summary.route,
      challenger: summary.challenger,
      pairs: summary.pairCount,
      wins: summary.total.challengerWins,
      losses: summary.total.baselineWins,
      undecided: summary.total.undecided,
      winRate: summary.winRate === null ? "" : `${Math.round(summary.winRate * 100)}%`,
      ...Object.fromEntries(judgeNames.map((judgeName) => [`${judgeName} decided`, `${Math.round(summary.agreementPerJudge[judgeName] * 100)}%`])),
      judgesAgree: summary.judgesAgreeShare === null ? "" : `${Math.round(summary.judgesAgreeShare * 100)}%`,
    })),
  );
  writeFileSync(join(outDirectory, "summary.json"), `${JSON.stringify(summaries, null, 2)}\n`);

  const spotCheckPairs = pickSpotChecks(pairs, Number(commandLineOption("spot-checks") ?? 10));
  const cards: SpotCheckCard[] = spotCheckPairs.map((pair: ReplyPair) => {
    const context = contextByCaseId.get(pair.caseId) as JudgeContext;
    // Which reply is A on the page is fixed by the pair, so the page never shows the baseline first every time.
    const shown = stableHash(pair.pairId) % 2 === 0 ? [pair.baseline, pair.challenger] : [pair.challenger, pair.baseline];
    const sideOfVerdict = (order: PairOrder, verdict: string) =>
      verdict === "tie" ? "tie" : (verdict === "A") === (order === 1) ? pair.baseline.side : pair.challenger.side;
    const verdictLines = judgments
      .filter((judgment) => judgment.pairId === pair.pairId)
      .sort((first, second) => first.judge.localeCompare(second.judge) || first.order - second.order)
      .map((judgment) => `${judgment.judge}, order ${judgment.order}: picked ${sideOfVerdict(judgment.order, judgment.verdict)}. ${judgment.reason}`);
    const imageFor = (reply: SavedReply) => (overlayImages.get(replyImageId(reply)) === undefined ? undefined : `${replyImageId(reply)}.png`);
    return {
      title: `${pair.route}, case ${pair.caseId}, run ${pair.runIndex + 1}`,
      request: requestSummary(context),
      replies: [
        { description: describeReply(context, shown[0].replyText), imageFileName: imageFor(shown[0]) },
        { description: describeReply(context, shown[1].replyText), imageFileName: imageFor(shown[1]) },
      ],
      reveal: [`A is ${shown[0].side} (${shown[0].models.join(", ")})`, `B is ${shown[1].side} (${shown[1].models.join(", ")})`, ...verdictLines].join("\n"),
    };
  });
  writeFileSync(join(outDirectory, "spotcheck.html"), spotCheckPage(cards));
  console.log(`saved ${join(outDirectory, "summary.json")}, ${judgmentsPath}, and the spot-check page ${join(outDirectory, "spotcheck.html")}`);
}

await main();
