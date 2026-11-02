import { describe, expect, it } from "vitest";
import whaleFixture from "../fixtures/whale.json";
import { sceneSpecSchema } from "./spec";

describe("scene spec", () => {
  it("parses the blue whale fixture", () => {
    const parsedWhale = sceneSpecSchema.parse(whaleFixture);

    expect(parsedWhale.title).toBe("Blue whale");
    expect(parsedWhale.cameraStops).toHaveLength(3);
    expect(parsedWhale.quiz.partId).toBe("heart");
    expect(parsedWhale.parts.map((part) => part.id)).toEqual([
      "body",
      "flipper",
      "dorsal-fin",
      "tail",
      "eye",
      "blowhole",
      "heart",
      "aorta",
      "pulmonary-artery",
      "left-lung",
      "right-lung",
      "liver",
      "stomach",
      "intestine",
      "spine",
      "ribs",
    ]);

    const body = parsedWhale.parts.find((part) => part.id === "body");
    expect(body?.opacity).toBeLessThan(1);
    expect(body?.skin?.grooves).toBe(true);
  });

  it("rejects a loft part with 3 stations", () => {
    const threeStationLoft = {
      id: "short-body",
      label: "Short body",
      shape: "loft",
      position: [0, 0, 0],
      color: "#4f6f8f",
      stations: [
        { x: 0, top: 0.1, bottom: 0.1, width: 0.1 },
        { x: 1, top: 0.4, bottom: 0.4, width: 0.4 },
        { x: 2, top: 0.1, bottom: 0.1, width: 0.1 },
      ],
    };

    const result = sceneSpecSchema.safeParse({
      ...whaleFixture,
      parts: [threeStationLoft],
      quiz: { partId: "short-body", question: whaleFixture.quiz.question },
    });

    expect(result.success).toBe(false);
  });

  it("rejects a 17-part spec", () => {
    const seventeenParts = Array.from({ length: 17 }, (_, partIndex) => {
      const sourcePart = whaleFixture.parts[partIndex % whaleFixture.parts.length];
      return {
        ...sourcePart,
        id: `part-${partIndex}`,
      };
    });

    const result = sceneSpecSchema.safeParse({
      ...whaleFixture,
      parts: seventeenParts,
      quiz: { partId: "part-0", question: whaleFixture.quiz.question },
    });

    expect(result.success).toBe(false);
  });

  it("rejects a quiz partId with no matching part", () => {
    const result = sceneSpecSchema.safeParse({
      ...whaleFixture,
      quiz: {
        partId: "does-not-exist",
        question: whaleFixture.quiz.question,
      },
    });

    expect(result.success).toBe(false);
    if (!result.success) {
      expect(
        result.error.issues.some((issue) => issue.path.includes("partId")),
      ).toBe(true);
    }
  });
});
