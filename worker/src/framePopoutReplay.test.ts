import { describe, expect, it } from "vitest";
// Vite reads the app's page as text. The page imports three.js and a lifted frame, so only its plain math block runs here.
import framePopoutSource from "../../leanring-buddy/LiveSceneAssets/frame-popout.html?raw";

type Box = { left: number; right: number; top: number; bottom: number };
type MediaRect = { left: number; top: number; width: number; height: number };

/** The page's pan clamp math, cut out of frame-popout.html between its markers and run as written. */
function loadThePanClampMath() {
  const blockStart = framePopoutSource.indexOf("// BEGIN pan clamp math");
  const blockEnd = framePopoutSource.indexOf("// END pan clamp math");
  expect(blockStart).toBeGreaterThan(0);
  expect(blockEnd).toBeGreaterThan(blockStart);
  const blockSource = framePopoutSource.slice(blockStart, blockEnd);
  return new Function(`${blockSource}; return { overflowOutsideTheMedia, largestPanShareThatKeepsTheSubjectInside };`)() as {
    overflowOutsideTheMedia: (box: Box, mediaRect: MediaRect) => number;
    largestPanShareThatKeepsTheSubjectInside: (overflowAtShare: (share: number) => number) => number;
  };
}

const media: MediaRect = { left: 100, top: 100, width: 400, height: 300 };

describe("frame-popout.html instant replay pan clamp", () => {
  it("counts how far a box reaches outside the media on each side", () => {
    const { overflowOutsideTheMedia } = loadThePanClampMath();
    expect(overflowOutsideTheMedia({ left: 150, right: 450, top: 150, bottom: 350 }, media)).toBe(0);
    expect(overflowOutsideTheMedia({ left: 80, right: 450, top: 150, bottom: 420 }, media)).toBe(20 + 20);
  });

  it("pans all the way to the part when the subject stays inside the media", () => {
    const { largestPanShareThatKeepsTheSubjectInside } = loadThePanClampMath();
    expect(largestPanShareThatKeepsTheSubjectInside(() => 0)).toBe(1);
  });

  it("stops the pan where the subject would start to leave the media", () => {
    // The subject's box slides 200 points right over a full pan and starts 60 points inside the media's right edge,
    // so it reaches the edge at a share of 0.3.
    const { overflowOutsideTheMedia, largestPanShareThatKeepsTheSubjectInside } = loadThePanClampMath();
    const overflowAtShare = (share: number) =>
      overflowOutsideTheMedia({ left: 240 + 200 * share, right: 440 + 200 * share, top: 150, bottom: 350 }, media);
    const share = largestPanShareThatKeepsTheSubjectInside(overflowAtShare);
    expect(share).toBeGreaterThan(0.29);
    expect(share).toBeLessThanOrEqual(0.3025);
  });

  it("lets a subject that already sticks out pan only while it sticks out no further", () => {
    // Zoomed in past the media's width, the box overflows on both sides, and the pan keeps that sum until its left edge comes inside.
    const { overflowOutsideTheMedia, largestPanShareThatKeepsTheSubjectInside } = loadThePanClampMath();
    const overflowAtShare = (share: number) =>
      overflowOutsideTheMedia({ left: 50 + 100 * share, right: 550 + 100 * share, top: 150, bottom: 350 }, media);
    const share = largestPanShareThatKeepsTheSubjectInside(overflowAtShare);
    expect(share).toBeGreaterThan(0.49);
    expect(share).toBeLessThanOrEqual(0.505);
  });
});

describe("frame-popout.html endFocus", () => {
  it("stops every eased camera value, so Escape during a replay leaves the camera still", () => {
    // The replay prototype on 2026-11-21 found that a camera ease endFocus does not stop runs on after Escape.
    // After the tour the page eases the pan (focusMove), the turn to a stop (poseMove), and the drag and zoom goals.
    const endFocusStart = framePopoutSource.indexOf("  endFocus() {");
    const endFocusBody = framePopoutSource.slice(endFocusStart, framePopoutSource.indexOf("\n  },", endFocusStart));
    expect(endFocusBody).toContain("focusMove = null;");
    expect(endFocusBody).toContain("poseMove = null;");
    expect(endFocusBody).toContain("heldTarget = target.clone();");
    expect(endFocusBody).toContain("draggedYaw = yaw; draggedPitch = pitch; restingCameraDistance = cameraDistance;");
    // The render loop reads the held target ahead of the focused part, so the pan stays where it froze.
    expect(framePopoutSource).toContain("const restingTarget = heldTarget ?? (");
  });

  it("lets a pinch or a voice zoom take the camera over from a replay stop's turn", () => {
    // The review of PR 88 found that zoomBy left the turn running, which set the distance back on every frame.
    const zoomByStart = framePopoutSource.indexOf("  zoomBy(amount) {");
    const zoomByBody = framePopoutSource.slice(zoomByStart, framePopoutSource.indexOf("\n  },", zoomByStart));
    expect(zoomByBody).toContain("poseMove = null;");
  });
});

describe("frame-popout.html focusStop", () => {
  it("turns back to a recorded yaw the shortest way round", () => {
    // A puffed-up model turns without limit, so a model dragged around twice would otherwise spin two turns back.
    const focusStopStart = framePopoutSource.indexOf("  focusStop(labelText, pose) {");
    const focusStopBody = framePopoutSource.slice(focusStopStart, framePopoutSource.indexOf("\n  },", focusStopStart));
    expect(focusStopBody).toContain("Math.atan2(Math.sin(pose.yaw - yaw), Math.cos(pose.yaw - yaw))");
    expect(focusStopBody).toContain("yaw + shortestYawTurn");
  });
});

describe("frame-popout.html replay stop numbers and path", () => {
  it("draws the path's accent through a style property and keeps a reached number apart from its focused label", () => {
    // The merge of PR 85 into PR 88 found that a CSS variable in an SVG presentation attribute is not promised to resolve,
    // and that a reached number and its focused label are both filled with the accent.
    expect(framePopoutSource).toContain('<path id="replayPathLine" d="" fill="none" style="stroke: var(--clicky-accent)"');
    const reachedRule = framePopoutSource.slice(framePopoutSource.indexOf(".replay-stop-number.reached {"));
    expect(reachedRule.slice(0, reachedRule.indexOf("}"))).toContain("border-color: var(--clicky-callout-surface)");
  });
});
