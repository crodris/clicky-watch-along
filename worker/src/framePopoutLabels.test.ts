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

  it("reports each label's anchor, the point its leader line and dot are drawn at, for the blue cursor to point at", () => {
    // The cursor flew to the label's words, not the part the label names. The page now sends the clamped anchor next to the
    // label's box, and the app falls back to the box only for a label with no anchor yet.
    const readerStart = framePopoutSource.indexOf("async labelRectsOnceTheCameraSettles()");
    expect(readerStart).toBeGreaterThan(-1);
    const reader = framePopoutSource.slice(readerStart, framePopoutSource.indexOf("\n};", readerStart));
    expect(reader).toMatch(/entry\.anchorX === undefined \? null : \{ x: entry\.anchorX, y: entry\.anchorY \}/);
    expect(reader).toMatch(/return \{ label: entry\.part\.label, left: rect\.left, top: rect\.top, width: rect\.width, height: rect\.height, anchor \};/);
    // It is the same clamped point the dot is drawn at, so the cursor and the dot cannot disagree.
    expect(framePopoutSource).toMatch(/entry\.anchorX = anchorX; entry\.anchorY = anchorY;/);
    expect(framePopoutSource).toMatch(/entry\.dot\.setAttribute\("cx", anchorX\); entry\.dot\.setAttribute\("cy", anchorY\);/);
  });
});

describe("frame-popout.html leader lines under a dimmed label", () => {
  /** The page's leader line math, cut out of frame-popout.html between its markers and run as written. */
  const loadTheLeaderLineMath = () => {
    const blockStart = framePopoutSource.indexOf("// BEGIN leader line math");
    const blockEnd = framePopoutSource.indexOf("// END leader line math");
    expect(blockStart).toBeGreaterThan(0);
    expect(blockEnd).toBeGreaterThan(blockStart);
    return new Function(`${framePopoutSource.slice(blockStart, blockEnd)}; return { leaderEndOnTheLabelEdge };`)() as {
      leaderEndOnTheLabelEdge: (anchorX: number, anchorY: number, labelX: number, labelY: number, halfWidth: number, halfHeight: number) => { x: number; y: number } | null;
    };
  };

  // A label 80 by 24 points at (300, 200), with the 4 and 3 points of padding the layout adds around it.
  const halfWidth = 40 + 4;
  const halfHeight = 12 + 3;

  it("ends the line on the label's edge, so it never runs under the label's words", () => {
    // A dimmed label is mostly see through, and a line that ended at the label's center showed through it like a strike
    // through its text.
    const { leaderEndOnTheLabelEdge } = loadTheLeaderLineMath();
    expect(leaderEndOnTheLabelEdge(100, 200, 300, 200, halfWidth, halfHeight)).toEqual({ x: 260, y: 200 });
    expect(leaderEndOnTheLabelEdge(300, 50, 300, 200, halfWidth, halfHeight)).toEqual({ x: 300, y: 188 });
    // Up and to the left, the end is on the box's boundary and on the line toward the part.
    const diagonalEnd = leaderEndOnTheLabelEdge(100, 100, 300, 200, halfWidth, halfHeight);
    expect(diagonalEnd).not.toBeNull();
    expect(diagonalEnd?.x).toBeCloseTo(300 - 12 * 2, 9);
    expect(diagonalEnd?.y).toBeCloseTo(200 - 12, 9);
  });

  it("draws no line for a part that sits under its label", () => {
    const { leaderEndOnTheLabelEdge } = loadTheLeaderLineMath();
    expect(leaderEndOnTheLabelEdge(310, 205, 300, 200, halfWidth, halfHeight)).toBeNull();
  });

  it("draws the line and the dot at the label's own opacity, and ends the line at the label's edge", () => {
    // The line and the dot stayed at full strength while a part's label dimmed to 0.35.
    expect(framePopoutSource).toMatch(/const drawnOpacity = returnFrom \? shownOpacity : Number\(entry\.element\.style\.opacity\);/);
    expect(framePopoutSource).toMatch(/entry\.line\.setAttribute\("opacity", leaderEnd \? drawnOpacity : 0\);/);
    expect(framePopoutSource).toMatch(/entry\.dot\.setAttribute\("opacity", drawnOpacity\);/);
    expect(framePopoutSource).not.toMatch(/entry\.line\.setAttribute\("x2", labelX\)/);
    expect(framePopoutSource).not.toMatch(/entry\.line\.setAttribute\("y2", labelY\)/);
  });
});
