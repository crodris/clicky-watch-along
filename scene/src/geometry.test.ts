import { Vector3 } from "three";
import { describe, expect, it } from "vitest";
import whaleFixture from "../fixtures/whale.json";
import { createFinGeometry, createLoftGeometry, createTubeGeometry } from "./geometry";
import { partSchema, sceneSpecSchema, type FinPart, type LoftPart } from "./spec";

const parsedWhale = sceneSpecSchema.parse(whaleFixture);

function plainLoft(): LoftPart {
  const parsedPart = partSchema.parse({
    id: "body",
    label: "",
    shape: "loft",
    position: [0, 0, 0],
    color: "#4f6f8f",
    stations: [
      { x: 0, top: 0.1, bottom: 0.1, width: 0.2 },
      { x: 1, top: 0.5, bottom: 0.6, width: 0.7 },
      { x: 2, top: 0.45, bottom: 0.5, width: 0.6 },
      { x: 3, top: 0.08, bottom: 0.08, width: 0.1 },
    ],
  });
  if (parsedPart.shape !== "loft") {
    throw new Error("Expected a loft part");
  }
  return parsedPart;
}

describe("generated geometry", () => {
  it("never bulges a loft past its largest station", () => {
    const bounds = createLoftGeometry(plainLoft()).boundingBox;

    expect(bounds?.max.z).toBeLessThanOrEqual(0.7);
    expect(bounds?.max.y).toBeLessThanOrEqual(0.5);
    expect(bounds?.min.y).toBeGreaterThanOrEqual(-0.6);
  });

  it("closes both ends of a loft a little past its first and last stations", () => {
    const bounds = createLoftGeometry(plainLoft()).boundingBox;

    expect(bounds?.min.x).toBeLessThan(0);
    expect(bounds?.min.x).toBeGreaterThan(-0.3);
    expect(bounds?.max.x).toBeGreaterThan(3);
    expect(bounds?.max.x).toBeLessThan(3.3);
  });

  it("points loft and fin normals away from the middle of the shape", () => {
    const flipper = parsedWhale.parts.find((part): part is FinPart => part.shape === "fin");
    if (flipper === undefined) {
      throw new Error("The whale fixture has no fin");
    }
    for (const geometry of [createLoftGeometry(plainLoft()), createFinGeometry(flipper)]) {
      geometry.computeBoundingSphere();
      const shapeCenter = geometry.boundingSphere?.center ?? new Vector3();
      const positions = geometry.getAttribute("position");
      const normals = geometry.getAttribute("normal");
      let outwardCount = 0;
      for (let vertexIndex = 0; vertexIndex < positions.count; vertexIndex += 1) {
        const outward = new Vector3().fromBufferAttribute(positions, vertexIndex).sub(shapeCenter);
        const normal = new Vector3().fromBufferAttribute(normals, vertexIndex);
        outwardCount += outward.dot(normal) > 0 ? 1 : 0;
      }
      expect(outwardCount / positions.count).toBeGreaterThan(0.9);
    }
  });

  it("builds every fixture tube with finite vertices", () => {
    for (const part of parsedWhale.parts) {
      if (part.shape !== "tube") {
        continue;
      }
      const positions = createTubeGeometry(part).getAttribute("position").array;
      expect(positions.every((value) => Number.isFinite(value))).toBe(true);
    }
  });
});
