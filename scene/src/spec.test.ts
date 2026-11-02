import { describe, expect, it } from "vitest";
import waterFixture from "../fixtures/water.json";
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

  it("parses the water fixture with a true 104.5 degree molecule", () => {
    const parsedWater = sceneSpecSchema.parse(waterFixture);

    expect(parsedWater.title).toBe("Water molecule");
    expect(parsedWater.quiz.partId).toBe("oxygen");
    expect(parsedWater.parts.map((part) => [part.id, part.label])).toEqual([
      ["droplet", "Water droplet"],
      ["oxygen", "Oxygen"],
      ["hydrogen-left", "Hydrogen"],
      ["hydrogen-right", "Hydrogen"],
      ["bond-left", "Bond"],
      ["bond-right", "Bond"],
    ]);

    const droplet = parsedWater.parts.find((part) => part.id === "droplet");
    expect(droplet?.opacity).toBeLessThan(1);
    expect(droplet?.tissue?.pattern).toBe("liquid");

    const positionOfPart = (partId: string): number[] => {
      const part = parsedWater.parts.find((candidatePart) => candidatePart.id === partId);
      if (part === undefined) {
        throw new Error(`Water fixture is missing ${partId}`);
      }
      return part.position;
    };
    const oxygenPosition = positionOfPart("oxygen");
    const armToHydrogen = (partId: string): number[] =>
      positionOfPart(partId).map((coordinate, axisIndex) => coordinate - oxygenPosition[axisIndex]);
    const leftArm = armToHydrogen("hydrogen-left");
    const rightArm = armToHydrogen("hydrogen-right");
    const armDotProduct = leftArm.reduce(
      (total, coordinate, axisIndex) => total + coordinate * rightArm[axisIndex],
      0,
    );
    const bondAngleDegrees =
      (Math.acos(armDotProduct / (Math.hypot(...leftArm) * Math.hypot(...rightArm))) * 180) / Math.PI;
    expect(bondAngleDegrees).toBeCloseTo(104.5, 1);
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
