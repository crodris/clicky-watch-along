// How judge.ts pairs replies, shows each pair in both A/B orders, and counts what the judging models say.
// Nothing here calls a model, so judgePairs.test.ts runs it all.

import type { SavedReply } from "./replyFiles.ts";

/**
 * A --side label is "<group>-<name>", such as parts-sol61, where the group is the bench run and the name is the
 * model setup. Replies are only paired inside one group.
 */
export function sideGroupAndName(sideLabel: string): { group: string; name: string } | undefined {
  const dashIndex = sideLabel.indexOf("-");
  if (dashIndex <= 0 || dashIndex === sideLabel.length - 1) {
    return undefined;
  }
  return { group: sideLabel.slice(0, dashIndex), name: sideLabel.slice(dashIndex + 1) };
}

/** A reply is worth judging only when the route answered and said something. */
export function replyIsUsable(reply: SavedReply): boolean {
  return reply.httpStatus === 200 && reply.replyText.trim() !== "";
}

export type ReplyPair = {
  /** Names the pair without naming a model's output, so a judgment can be saved and found again. */
  pairId: string;
  caseId: string;
  route: string;
  runIndex: number;
  baseline: SavedReply;
  challenger: SavedReply;
};

export type PairingResult = {
  pairs: ReplyPair[];
  /** Pairs left out because one reply failed, which the pass counts already show. */
  unusablePairCount: number;
};

/**
 * Pairs the baseline's reply with each challenger's reply to the same case and run, for the first `pairsPerCase`
 * runs both sides have. The baseline is the side named `baselineName` in its group.
 */
export function buildPairs(
  replies: SavedReply[],
  options: { baselineName: string; pairsPerCase: number; routes?: string[] },
): PairingResult {
  const replyBySideCaseRun = new Map<string, SavedReply>();
  for (const reply of replies) {
    replyBySideCaseRun.set(`${reply.side}|${reply.caseId}|${reply.runIndex}`, reply);
  }

  const pairs: ReplyPair[] = [];
  let unusablePairCount = 0;
  const baselines = replies.filter((reply) => sideGroupAndName(reply.side)?.name === options.baselineName);
  const challengers = replies.filter((reply) => {
    const sideParts = sideGroupAndName(reply.side);
    return sideParts !== undefined && sideParts.name !== options.baselineName;
  });

  const runsPerBaselineCase = new Map<string, number[]>();
  for (const baseline of baselines) {
    const caseKey = `${baseline.side}|${baseline.caseId}`;
    runsPerBaselineCase.set(caseKey, [...(runsPerBaselineCase.get(caseKey) ?? []), baseline.runIndex]);
  }

  const challengerSides = [...new Set(challengers.map((challenger) => challenger.side))].sort();
  for (const [caseKey, baselineRuns] of [...runsPerBaselineCase].sort(([firstKey], [secondKey]) => firstKey.localeCompare(secondKey))) {
    const [baselineSide, caseId] = caseKey.split("|");
    const baselineGroup = sideGroupAndName(baselineSide)?.group;
    for (const challengerSide of challengerSides.filter((side) => sideGroupAndName(side)?.group === baselineGroup)) {
      const runsInBoth = baselineRuns
        .filter((runIndex) => replyBySideCaseRun.has(`${challengerSide}|${caseId}|${runIndex}`))
        .sort((firstRun, secondRun) => firstRun - secondRun)
        .slice(0, options.pairsPerCase);
      for (const runIndex of runsInBoth) {
        const baseline = replyBySideCaseRun.get(`${baselineSide}|${caseId}|${runIndex}`);
        const challenger = replyBySideCaseRun.get(`${challengerSide}|${caseId}|${runIndex}`);
        if (baseline === undefined || challenger === undefined) {
          continue;
        }
        if (options.routes !== undefined && !options.routes.includes(baseline.route)) {
          continue;
        }
        if (!replyIsUsable(baseline) || !replyIsUsable(challenger)) {
          unusablePairCount += 1;
          continue;
        }
        pairs.push({ pairId: `${caseId}|${baselineSide}|${challengerSide}|${runIndex}`, caseId, route: baseline.route, runIndex, baseline, challenger });
      }
    }
  }
  return { pairs, unusablePairCount };
}

export type PairOrder = 1 | 2;

/** What the judging model sees in one call: two replies as A and B, with no side labels. */
export type Presentation = { order: PairOrder; a: SavedReply; b: SavedReply };

/**
 * Every pair goes to each judge twice, with the replies swapped, so a judge that favors the first or the second
 * reply cannot decide a pair alone. Order 1 shows the baseline as A, and order 2 shows the challenger as A.
 */
export function presentationsOf(pair: ReplyPair): [Presentation, Presentation] {
  return [
    { order: 1, a: pair.baseline, b: pair.challenger },
    { order: 2, a: pair.challenger, b: pair.baseline },
  ];
}

export type Verdict = "A" | "B" | "tie";

export type PairOutcome = "challenger" | "baseline" | "undecided";

/**
 * A win counts only when the judge picks the same reply in both orders. A tie in either order, or a pick of A in
 * both orders, which means the judge followed position and not the replies, leaves the pair undecided.
 */
export function outcomeOfPair(verdictInOrder1: Verdict, verdictInOrder2: Verdict): PairOutcome {
  if (verdictInOrder1 === "A" && verdictInOrder2 === "B") {
    return "baseline";
  }
  if (verdictInOrder1 === "B" && verdictInOrder2 === "A") {
    return "challenger";
  }
  return "undecided";
}

export type Judgment = { pairId: string; judge: string; order: PairOrder; verdict: Verdict; reason: string };

export type JudgeTally = { challengerWins: number; baselineWins: number; undecided: number };

export type ChallengerSummary = {
  route: string;
  /** The challenger's side name, such as sol61. */
  challenger: string;
  pairCount: number;
  perJudge: Record<string, JudgeTally>;
  total: JudgeTally;
  /** Challenger wins over decided calls, or null when no call was decided. */
  winRate: number | null;
  /** The share of each judge's pairs it decided in both orders. A low share means the judge follows position. */
  agreementPerJudge: Record<string, number>;
  /** Of the pairs both judges decided, the share where they picked the same reply. Null when no pair was decided by both. */
  judgesAgreeShare: number | null;
};

/** Counts each judge's outcome for every pair that has both of its orders judged. */
export function summarizeJudgments(pairs: ReplyPair[], judgments: Judgment[], judgeNames: string[]): ChallengerSummary[] {
  const verdictByKey = new Map(judgments.map((judgment) => [`${judgment.pairId}|${judgment.judge}|${judgment.order}`, judgment.verdict]));
  const summaries = new Map<string, ChallengerSummary & { bothDecidedCount: number; bothAgreedCount: number }>();

  for (const pair of pairs) {
    const challengerName = sideGroupAndName(pair.challenger.side)?.name ?? pair.challenger.side;
    const summaryKey = `${pair.route}|${challengerName}`;
    let summary = summaries.get(summaryKey);
    if (summary === undefined) {
      summary = {
        route: pair.route,
        challenger: challengerName,
        pairCount: 0,
        perJudge: Object.fromEntries(judgeNames.map((judgeName) => [judgeName, { challengerWins: 0, baselineWins: 0, undecided: 0 }])),
        total: { challengerWins: 0, baselineWins: 0, undecided: 0 },
        winRate: null,
        agreementPerJudge: {},
        judgesAgreeShare: null,
        bothDecidedCount: 0,
        bothAgreedCount: 0,
      };
      summaries.set(summaryKey, summary);
    }
    summary.pairCount += 1;

    const decidedOutcomes: PairOutcome[] = [];
    for (const judgeName of judgeNames) {
      const verdictInOrder1 = verdictByKey.get(`${pair.pairId}|${judgeName}|1`);
      const verdictInOrder2 = verdictByKey.get(`${pair.pairId}|${judgeName}|2`);
      if (verdictInOrder1 === undefined || verdictInOrder2 === undefined) {
        continue;
      }
      const outcome = outcomeOfPair(verdictInOrder1, verdictInOrder2);
      const tallyKey = outcome === "challenger" ? "challengerWins" : outcome === "baseline" ? "baselineWins" : "undecided";
      summary.perJudge[judgeName][tallyKey] += 1;
      summary.total[tallyKey] += 1;
      if (outcome !== "undecided") {
        decidedOutcomes.push(outcome);
      }
    }
    if (judgeNames.length === 2 && decidedOutcomes.length === 2) {
      summary.bothDecidedCount += 1;
      summary.bothAgreedCount += decidedOutcomes[0] === decidedOutcomes[1] ? 1 : 0;
    }
  }

  return [...summaries.values()]
    .sort((first, second) => first.route.localeCompare(second.route) || first.challenger.localeCompare(second.challenger))
    .map(({ bothDecidedCount, bothAgreedCount, ...summary }) => {
      const decidedCount = summary.total.challengerWins + summary.total.baselineWins;
      return {
        ...summary,
        winRate: decidedCount === 0 ? null : summary.total.challengerWins / decidedCount,
        agreementPerJudge: Object.fromEntries(
          judgeNames.map((judgeName) => {
            const tally = summary.perJudge[judgeName];
            const judgedCount = tally.challengerWins + tally.baselineWins + tally.undecided;
            return [judgeName, judgedCount === 0 ? 0 : (tally.challengerWins + tally.baselineWins) / judgedCount];
          }),
        ),
        judgesAgreeShare: bothDecidedCount === 0 ? null : bothAgreedCount / bothDecidedCount,
      };
    });
}

/** A short stable number from text, so a spot check's A/B assignment and order never change between runs. */
export function stableHash(text: string): number {
  let hash = 2166136261;
  for (const character of text) {
    hash = Math.imul(hash ^ (character.codePointAt(0) ?? 0), 16777619) >>> 0;
  }
  return hash;
}

/** Spreads the spot checks across routes, taking each route's pairs in a fixed shuffled order, so one route cannot fill the page. */
export function pickSpotChecks(pairs: ReplyPair[], count: number): ReplyPair[] {
  const pairsByRoute = new Map<string, ReplyPair[]>();
  for (const pair of [...pairs].sort((first, second) => stableHash(first.pairId) - stableHash(second.pairId))) {
    pairsByRoute.set(pair.route, [...(pairsByRoute.get(pair.route) ?? []), pair]);
  }
  const routeQueues = [...pairsByRoute].sort(([firstRoute], [secondRoute]) => firstRoute.localeCompare(secondRoute)).map(([, routePairs]) => routePairs);
  const picked: ReplyPair[] = [];
  while (picked.length < count && routeQueues.some((queue) => queue.length > 0)) {
    for (const queue of routeQueues) {
      const nextPair = queue.shift();
      if (nextPair !== undefined && picked.length < count) {
        picked.push(nextPair);
      }
    }
  }
  return picked;
}
