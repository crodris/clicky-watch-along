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

  it("clamps each leader line's part end into the window too, so a line never points off screen after a resize", () => {
    // Deferred from the quick fixes PR: the label was clamped, but its line still started at the projected part point,
    // which a window that shrank after the scene loaded leaves outside what shows.
    expect(framePopoutSource).toMatch(/const anchorX = keepLabelXInViewport\(pointX, 0\), anchorY = keepLabelYInViewport\(pointY, 0\);/);
    expect(framePopoutSource).toMatch(/entry\.line\.setAttribute\("x1", anchorX\); entry\.line\.setAttribute\("y1", anchorY\);/);
    expect(framePopoutSource).toMatch(/entry\.dot\.setAttribute\("cx", anchorX\); entry\.dot\.setAttribute\("cy", anchorY\);/);
    expect(framePopoutSource).not.toMatch(/setAttribute\("x1", pointX\)/);
  });
});
