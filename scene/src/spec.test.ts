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
      "heart",
      "left-lung",
      "right-lung",
      "stomach",
      "spine",
      "blowhole",
      "dorsal-fin",
      "tail",
    ]);

    const body = parsedWhale.parts.find((part) => part.id === "body");
    expect(body?.opacity).toBeCloseTo(0.25);
  });

  it("rejects an 11-part spec", () => {
    const elevenParts = Array.from({ length: 11 }, (_, partIndex) => {
      const sourcePart = whaleFixture.parts[partIndex % whaleFixture.parts.length];
      return {
        ...sourcePart,
        id: `part-${partIndex}`,
      };
    });

    const result = sceneSpecSchema.safeParse({
      ...whaleFixture,
      parts: elevenParts,
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
