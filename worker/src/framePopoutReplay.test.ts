import { describe, expect, it } from "vitest";
// Vite reads the app's page as text. The page imports three.js and a lifted frame, so only its plain math block runs here.
import framePopoutSource from "../../leanring-buddy/LiveSceneAssets/frame-popout.html?raw";

type Box = { left: number; right: number; top: number; bottom: number };
type MediaRect = { left: number; top: number; width: number; height: number };
type OverflowOnEachSide = { left: number; right: number; top: number; bottom: number };

/** The page's pan clamp math, cut out of frame-popout.html between its markers and run as written. */
function loadThePanClampMath() {
  const blockStart = framePopoutSource.indexOf("// BEGIN pan clamp math");
  const blockEnd = framePopoutSource.indexOf("// END pan clamp math");
  expect(blockStart).toBeGreaterThan(0);
  expect(blockEnd).toBeGreaterThan(blockStart);
  const blockSource = framePopoutSource.slice(blockStart, blockEnd);
  return new Function(
    `${blockSource}; return { overflowOnEachSide, largestPanShareThatKeepsTheSubjectInside, cameraDistanceThatFitsTheSubject, slideThatCentersTheBoxOnTheMedia };`,
  )() as {
    overflowOnEachSide: (box: Box, mediaRect: MediaRect) => OverflowOnEachSide;
    largestPanShareThatKeepsTheSubjectInside: (overflowOnEachSideAtShare: (share: number) => OverflowOnEachSide) => number;
    cameraDistanceThatFitsTheSubject: (chosenDistance: number, subjectBoxAtDistance: (distance: number) => Box, roomRect: MediaRect) => number;
    slideThatCentersTheBoxOnTheMedia: (box: Box, mediaRect: MediaRect) => { right: number; down: number };
  };
}

const media: MediaRect = { left: 100, top: 100, width: 400, height: 300 };
const noOverflow: OverflowOnEachSide = { left: 0, right: 0, top: 0, bottom: 0 };

/** A box this wide and tall at a distance of 1000, centered on this page point, that shrinks in proportion to the distance. */
const boxThatShrinksWithDistance = (widthAt1000: number, heightAt1000: number, centerX: number, centerY: number) => (distance: number): Box => ({
  left: centerX - (widthAt1000 * 1000) / distance / 2,
  right: centerX + (widthAt1000 * 1000) / distance / 2,
  top: centerY - (heightAt1000 * 1000) / distance / 2,
  bottom: centerY + (heightAt1000 * 1000) / distance / 2,
});

describe("frame-popout.html instant replay pan clamp", () => {
  it("counts how far a box reaches outside the media on each side", () => {
    const { overflowOnEachSide } = loadThePanClampMath();
    expect(overflowOnEachSide({ left: 150, right: 450, top: 150, bottom: 350 }, media)).toEqual(noOverflow);
    expect(overflowOnEachSide({ left: 80, right: 450, top: 150, bottom: 420 }, media)).toEqual({ left: 20, right: 0, top: 0, bottom: 20 });
  });

  it("pans all the way to the part when the subject stays inside the media", () => {
    const { largestPanShareThatKeepsTheSubjectInside } = loadThePanClampMath();
    expect(largestPanShareThatKeepsTheSubjectInside(() => noOverflow)).toBe(1);
  });

  it("stops the pan where the subject would start to leave the media", () => {
    // The subject's box slides 200 points right over a full pan and starts 60 points inside the media's right edge,
    // so it reaches the edge at a share of 0.3.
    const { overflowOnEachSide, largestPanShareThatKeepsTheSubjectInside } = loadThePanClampMath();
    const overflowAtShare = (share: number) =>
      overflowOnEachSide({ left: 240 + 200 * share, right: 440 + 200 * share, top: 150, bottom: 350 }, media);
    const share = largestPanShareThatKeepsTheSubjectInside(overflowAtShare);
    expect(share).toBeGreaterThan(0.29);
    expect(share).toBeLessThanOrEqual(0.3025);
  });

  it("keeps a subject wider than the media from leaning onto one side", () => {
    // The box sticks out 50 points on each side. A summed overflow let the pan move all of it to the right, over the page
    // beside the video, since the left side came in by as much as the right went out. On YouTube that is the sidebar.
    const { overflowOnEachSide, largestPanShareThatKeepsTheSubjectInside } = loadThePanClampMath();
    const overflowAtShare = (share: number) =>
      overflowOnEachSide({ left: 50 + 100 * share, right: 550 + 100 * share, top: 150, bottom: 350 }, media);
    expect(largestPanShareThatKeepsTheSubjectInside(overflowAtShare)).toBeLessThanOrEqual(0.005);
  });

  it("lets a subject that sticks out at the bottom still pan sideways until another side reaches the edge", () => {
    // Each side is held to its own overflow at the start, so the bottom's 30 points never let the right side out.
    const { overflowOnEachSide, largestPanShareThatKeepsTheSubjectInside } = loadThePanClampMath();
    const overflowAtShare = (share: number) =>
      overflowOnEachSide({ left: 200 + 200 * share, right: 400 + 200 * share, top: 200, bottom: 430 }, media);
    const share = largestPanShareThatKeepsTheSubjectInside(overflowAtShare);
    expect(share).toBeGreaterThan(0.49);
    expect(share).toBeLessThanOrEqual(0.505);
  });
});

describe("frame-popout.html camera distance for a focused part", () => {
  it("moves the camera out until a subject wider than the media fits inside it", () => {
    const { cameraDistanceThatFitsTheSubject, overflowOnEachSide } = loadThePanClampMath();
    // At the chosen distance the box is 600 points wide, half again as wide as the media.
    const boxAtDistance = boxThatShrinksWithDistance(600, 250, 300, 250);
    const distance = cameraDistanceThatFitsTheSubject(1000, boxAtDistance, media);
    expect(distance).toBeCloseTo(1500, 0);
    expect(overflowOnEachSide(boxAtDistance(distance), media)).toEqual(noOverflow);
  });

  it("moves the camera out until a subject taller than the media fits inside it", () => {
    // A puffed-up bicycle on a video page was narrower than the video and 180 points taller.
    const { cameraDistanceThatFitsTheSubject, overflowOnEachSide } = loadThePanClampMath();
    const boxAtDistance = boxThatShrinksWithDistance(300, 450, 300, 250);
    const distance = cameraDistanceThatFitsTheSubject(1000, boxAtDistance, media);
    expect(distance).toBeCloseTo(1500, 0);
    expect(overflowOnEachSide(boxAtDistance(distance), media)).toEqual(noOverflow);
  });

  it("never moves the camera nearer than the distance it was given", () => {
    const { cameraDistanceThatFitsTheSubject } = loadThePanClampMath();
    expect(cameraDistanceThatFitsTheSubject(1000, boxThatShrinksWithDistance(200, 100, 300, 250), media)).toBe(1000);
  });

  it("fits a box that shrinks more slowly than the distance grows, as the far side of a turned subject does", () => {
    const { cameraDistanceThatFitsTheSubject } = loadThePanClampMath();
    // The width goes as 1 over the distance plus 300, so a single move out leaves the box about 9 points too wide.
    const boxAtDistance = (distance: number): Box => {
      const width = (700 * 1300) / (distance + 300);
      return { left: 300 - width / 2, right: 300 + width / 2, top: 200, bottom: 300 };
    };
    const fittedBox = boxAtDistance(cameraDistanceThatFitsTheSubject(1000, boxAtDistance, media));
    expect(fittedBox.right - fittedBox.left).toBeLessThanOrEqual(400.5);
  });
});

describe("frame-popout.html start of the pan", () => {
  it("slides a subject that the window centers beside the video back over the video", () => {
    // A video page puts the video left of the window's middle, beside its sidebar, and the camera centers the subject in the window.
    const { slideThatCentersTheBoxOnTheMedia, cameraDistanceThatFitsTheSubject, overflowOnEachSide } = loadThePanClampMath();
    const boxCenteredOnTheWindow = boxThatShrinksWithDistance(600, 200, 700, 300);
    const box = boxCenteredOnTheWindow(cameraDistanceThatFitsTheSubject(1000, boxCenteredOnTheWindow, media));
    const slide = slideThatCentersTheBoxOnTheMedia(box, media);
    expect(slide).toEqual({ right: -400, down: -50 });
    const slidBox = { left: box.left + slide.right, right: box.right + slide.right, top: box.top + slide.down, bottom: box.bottom + slide.down };
    expect(overflowOnEachSide(slidBox, media)).toEqual(noOverflow);
  });
});

describe("frame-popout.html focus wiring", () => {
  // The page needs three.js and a lifted frame to run, so these check that the focus and the replay stop use the math above.
  // The headless Chrome check in the change that added them measured the lifted model inside the video at every stop.
  const methodBody = (signature: string) => {
    const bodyStart = framePopoutSource.indexOf(signature);
    expect(bodyStart).toBeGreaterThan(0);
    return framePopoutSource.slice(bodyStart, framePopoutSource.indexOf("\n  },", bodyStart));
  };

  it("keeps the camera's distance for a focus alone, since the zoom_to_part voice tool and the quiz hint call it too", () => {
    // The review of PR 112 found that a move-out here shrank the model when the learner asked to zoom in on a part.
    expect(methodBody("  focusPart(labelText) {")).not.toContain("cameraDistanceThatFitsTheFocusedSubject");
  });

  it("moves a replay stop's recorded distance out when the subject would not fit, no farther than a zoom reaches", () => {
    const focusStopBody = methodBody("  focusStop(labelText, pose) {");
    expect(focusStopBody).toContain("const toDistance = Math.min(maximumDistance, cameraDistanceThatFitsTheFocusedSubject(toYaw, toPitch, recordedDistance));");
    // The stop eases there through the pose move, which endFocus stops.
    expect(focusStopBody).toContain("poseMove = { startedAt: performance.now(), fromYaw: yaw, fromPitch: pitch, fromDistance: cameraDistance, toYaw, toPitch, toDistance };");
    expect(methodBody("  endFocus() {")).toContain("poseMove = null;");
  });

  it("starts the pan from the subject over the video and holds each side inside the room in the video", () => {
    const focusTargetSource = framePopoutSource.slice(framePopoutSource.indexOf("const focusTargetThatKeepsTheSubjectOverTheMedia"));
    expect(focusTargetSource).toContain("const fromPoint = targetThatCentersTheSubjectOnTheMedia()");
    expect(focusTargetSource).toContain("overflowOnEachSide(subjectBoxOnPage(candidate.lerpVectors(fromPoint, toPoint, share)), roomForTheFocusedSubject)");
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
