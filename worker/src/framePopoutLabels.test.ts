import { describe, expect, it } from "vitest";
// Vite reads the app's page as text. The page imports three.js and a lifted frame, so it cannot run here.
import framePopoutSource from "../../leanring-buddy/LiveSceneAssets/frame-popout.html?raw";

describe("frame-popout.html part labels", () => {
  it("clamps each label against the live window size, not the size taken at load", () => {
    // pageWidth and pageHeight are fixed when the page loads, so a window that changes size afterward would leave a
    // label outside what shows. Checked in headless Chrome on 2026-11-21: after a resize from 1440x810 to 900x500 the old
    // clamp left labels 495 points past the right edge, and the live size keeps each 11 points or more inside.
    const clampCalls = framePopoutSource.match(/keepLabelAxisInViewport\([^)]*\)/g) ?? [];
    const callsThatTakeTheLoadTimeSize = clampCalls.filter((call) => /pageWidth|pageHeight/.test(call));
    expect(clampCalls.length).toBeGreaterThan(0);
    expect(callsThatTakeTheLoadTimeSize).toEqual([]);
    expect(framePopoutSource).toMatch(/keepLabelAxisInViewport\(position, halfSize, innerWidth\)/);
    expect(framePopoutSource).toMatch(/keepLabelAxisInViewport\(position, halfSize, innerHeight\)/);
  });
});
