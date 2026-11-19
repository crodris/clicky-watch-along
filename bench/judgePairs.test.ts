import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  buildPairs,
  outcomeOfPair,
  pickSpotChecks,
  presentationsOf,
  sideGroupAndName,
  summarizeJudgments,
  type Judgment,
  type ReplyPair,
  type Verdict,
} from "./judgePairs.ts";
import type { SavedReply } from "./replyFiles.ts";

function reply(side: string, caseId: string, runIndex: number, overrides: Partial<SavedReply> = {}): SavedReply {
  return {
    side,
    caseId,
    route: caseId.startsWith("chat") ? "/chat" : "/video-frame-parts",
    runIndex,
    httpStatus: 200,
    qualityPassed: true,
    models: ["m"],
    replyText: `${side} ${caseId} ${runIndex}`,
    ...overrides,
  };
}

describe("sideGroupAndName", () => {
  it("splits a side label at its first dash, so a name may hold dashes", () => {
    assert.deepEqual(sideGroupAndName("parts-sol61"), { group: "parts", name: "sol61" });
    assert.deepEqual(sideGroupAndName("parts-gpt-6-luna"), { group: "parts", name: "gpt-6-luna" });
  });

  it("gives nothing for a label with no group or no name", () => {
    assert.equal(sideGroupAndName("base"), undefined);
    assert.equal(sideGroupAndName("-base"), undefined);
    assert.equal(sideGroupAndName("parts-"), undefined);
  });
});

describe("buildPairs", () => {
  const replies = [
    ...["a", "b"].flatMap((caseId) => ["parts-base", "parts-opus", "parts-sol"].flatMap((side) => [0, 1, 2].map((runIndex) => reply(side, caseId, runIndex)))),
    // Another group has its own baseline, and must never pair with this one.
    reply("chat-base", "chat-first", 0),
    reply("chat-luna", "chat-first", 0),
  ];

  it("pairs the baseline with each challenger of its group, one pair per case for the first run by default", () => {
    const { pairs } = buildPairs(replies, { baselineName: "base", pairsPerCase: 1 });

    assert.deepEqual(
      pairs.map((pair) => [pair.baseline.side, pair.challenger.side, pair.caseId, pair.runIndex]),
      [
        ["chat-base", "chat-luna", "chat-first", 0],
        ["parts-base", "parts-opus", "a", 0],
        ["parts-base", "parts-sol", "a", 0],
        ["parts-base", "parts-opus", "b", 0],
        ["parts-base", "parts-sol", "b", 0],
      ],
    );
  });

  it("pairs the same run of both sides, up to the runs asked for", () => {
    const { pairs } = buildPairs(replies, { baselineName: "base", pairsPerCase: 2, routes: ["/video-frame-parts"] });

    assert.equal(pairs.length, 8);
    assert.ok(pairs.every((pair) => pair.baseline.runIndex === pair.challenger.runIndex && pair.baseline.caseId === pair.challenger.caseId));
    assert.deepEqual([...new Set(pairs.map((pair) => pair.runIndex))], [0, 1]);
  });

  it("never pairs a baseline with a challenger from another group that ran the same case", () => {
    const { pairs } = buildPairs(
      [reply("parts-base", "a", 0), reply("parts-sol", "a", 0), reply("other-base", "a", 0), reply("other-luna", "a", 0)],
      { baselineName: "base", pairsPerCase: 1 },
    );

    assert.deepEqual(pairs.map((pair) => [pair.baseline.side, pair.challenger.side]).sort(), [["other-base", "other-luna"], ["parts-base", "parts-sol"]]);
  });

  it("keeps only the routes asked for", () => {
    const { pairs } = buildPairs(replies, { baselineName: "base", pairsPerCase: 1, routes: ["/chat"] });

    assert.deepEqual(pairs.map((pair) => pair.caseId), ["chat-first"]);
  });

  it("skips a run one side lacks, and counts a pair with a failed or empty reply as unusable", () => {
    const sideReplies = [
      reply("parts-base", "a", 0),
      reply("parts-opus", "a", 1),
      reply("parts-base", "b", 0),
      reply("parts-opus", "b", 0, { httpStatus: 500 }),
      reply("parts-base", "c", 0),
      reply("parts-opus", "c", 0, { replyText: "  " }),
      reply("parts-base", "d", 0),
      reply("parts-opus", "d", 0),
    ];

    const { pairs, unusablePairCount } = buildPairs(sideReplies, { baselineName: "base", pairsPerCase: 1 });

    assert.deepEqual(pairs.map((pair) => pair.caseId), ["d"]);
    assert.equal(unusablePairCount, 2);
  });

  it("gives a pair an id that names no model output, and finds the same one again", () => {
    const first = buildPairs(replies, { baselineName: "base", pairsPerCase: 1 }).pairs;
    const second = buildPairs([...replies].reverse(), { baselineName: "base", pairsPerCase: 1 }).pairs;

    assert.deepEqual(first.map((pair) => pair.pairId), second.map((pair) => pair.pairId));
    assert.equal(new Set(first.map((pair) => pair.pairId)).size, first.length);
  });

  it("finds no pair when no side is the baseline", () => {
    const { pairs } = buildPairs([reply("parts-opus", "a", 0), reply("parts-sol", "a", 0)], { baselineName: "base", pairsPerCase: 1 });

    assert.deepEqual(pairs, []);
  });
});

describe("presentationsOf", () => {
  const pair = buildPairs([reply("parts-base", "a", 0), reply("parts-opus", "a", 0)], { baselineName: "base", pairsPerCase: 1 }).pairs[0];

  it("shows the two replies in both orders, the baseline first and then the challenger first", () => {
    const [firstOrder, secondOrder] = presentationsOf(pair);

    assert.deepEqual([firstOrder.order, firstOrder.a.side, firstOrder.b.side], [1, "parts-base", "parts-opus"]);
    assert.deepEqual([secondOrder.order, secondOrder.a.side, secondOrder.b.side], [2, "parts-opus", "parts-base"]);
  });
});

describe("outcomeOfPair", () => {
  it("counts a win only when the judge picks the same reply in both orders", () => {
    // Order 1 shows the baseline as A, and order 2 shows the challenger as A.
    assert.equal(outcomeOfPair("B", "A"), "challenger");
    assert.equal(outcomeOfPair("A", "B"), "baseline");
  });

  it("leaves a pair undecided when the judge follows position or calls a tie", () => {
    const undecidedPairs: Array<[Verdict, Verdict]> = [["A", "A"], ["B", "B"], ["tie", "A"], ["B", "tie"], ["tie", "tie"]];

    for (const [firstVerdict, secondVerdict] of undecidedPairs) {
      assert.equal(outcomeOfPair(firstVerdict, secondVerdict), "undecided", `${firstVerdict} then ${secondVerdict}`);
    }
  });
});

describe("summarizeJudgments", () => {
  const pairs = buildPairs(
    [reply("parts-base", "a", 0), reply("parts-sol", "a", 0), reply("parts-base", "b", 0), reply("parts-sol", "b", 0), reply("parts-base", "c", 0), reply("parts-sol", "c", 0)],
    { baselineName: "base", pairsPerCase: 1 },
  ).pairs;

  function judgment(pairIndex: number, judge: string, order: 1 | 2, verdict: Verdict): Judgment {
    return { pairId: pairs[pairIndex].pairId, judge, order, verdict, reason: "" };
  }

  // Pair 0: both judges say the challenger. Pair 1: opus says baseline, sol says challenger. Pair 2: opus follows position, sol is missing.
  const judgments: Judgment[] = [
    judgment(0, "opus", 1, "B"), judgment(0, "opus", 2, "A"), judgment(0, "sol", 1, "B"), judgment(0, "sol", 2, "A"),
    judgment(1, "opus", 1, "A"), judgment(1, "opus", 2, "B"), judgment(1, "sol", 1, "B"), judgment(1, "sol", 2, "A"),
    judgment(2, "opus", 1, "A"), judgment(2, "opus", 2, "A"),
  ];

  it("tallies each judge's decided and undecided pairs, and the challenger's win rate over decided calls", () => {
    const [summary] = summarizeJudgments(pairs, judgments, ["opus", "sol"]);

    assert.equal(summary.route, "/video-frame-parts");
    assert.equal(summary.challenger, "sol");
    assert.equal(summary.pairCount, 3);
    assert.deepEqual(summary.perJudge.opus, { challengerWins: 1, baselineWins: 1, undecided: 1 });
    assert.deepEqual(summary.perJudge.sol, { challengerWins: 2, baselineWins: 0, undecided: 0 });
    assert.deepEqual(summary.total, { challengerWins: 3, baselineWins: 1, undecided: 1 });
    assert.equal(summary.winRate, 0.75);
  });

  it("reports how often each judge decided, and how often the two judges agreed", () => {
    const [summary] = summarizeJudgments(pairs, judgments, ["opus", "sol"]);

    assert.ok(Math.abs(summary.agreementPerJudge.opus - 2 / 3) < 1e-9);
    assert.equal(summary.agreementPerJudge.sol, 1);
    // Both judges decided pairs 0 and 1, and agreed on pair 0 only.
    assert.equal(summary.judgesAgreeShare, 0.5);
  });

  it("has no win rate before any call is decided", () => {
    const [summary] = summarizeJudgments(pairs, [], ["opus", "sol"]);

    assert.equal(summary.winRate, null);
    assert.equal(summary.judgesAgreeShare, null);
  });

  it("ignores a pair with only one of its two orders judged", () => {
    const [summary] = summarizeJudgments(pairs, [judgment(0, "opus", 1, "B")], ["opus", "sol"]);

    assert.deepEqual(summary.total, { challengerWins: 0, baselineWins: 0, undecided: 0 });
  });
});

describe("pickSpotChecks", () => {
  const pairs: ReplyPair[] = buildPairs(
    ["a", "b", "c", "d", "e"].flatMap((caseId) => [reply("parts-base", caseId, 0), reply("parts-sol", caseId, 0)]).concat(
      ["chat-first", "chat-followup"].flatMap((caseId) => [reply("parts-base", caseId, 0), reply("parts-sol", caseId, 0)]),
    ),
    { baselineName: "base", pairsPerCase: 1 },
  ).pairs;

  it("takes pairs from every route before it takes a second from one", () => {
    const picked = pickSpotChecks(pairs, 4);

    assert.equal(picked.filter((pair) => pair.route === "/chat").length, 2);
    assert.equal(picked.filter((pair) => pair.route === "/video-frame-parts").length, 2);
  });

  it("picks the same pairs every time, whatever order they come in", () => {
    assert.deepEqual(pickSpotChecks(pairs, 5).map((pair) => pair.pairId), pickSpotChecks([...pairs].reverse(), 5).map((pair) => pair.pairId));
  });

  it("returns every pair when fewer are asked for than exist, and never more", () => {
    assert.equal(pickSpotChecks(pairs, 100).length, pairs.length);
    assert.equal(pickSpotChecks(pairs, 0).length, 0);
  });
});
