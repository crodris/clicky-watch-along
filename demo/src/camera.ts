import { interpolate } from "remotion";
import { cameraEase, frameRate, punchInFrames } from "./motion.ts";

/** A point in the recording, from 0 to 1 on each axis, or the tracked Clicky triangle and its speech bubble. */
export type CameraFocus = { x: number; y: number } | "cursor";

/** From `atSeconds` into the shot, the camera eases to this scale and focus. */
export type CameraMove = {
  atSeconds: number;
  scale: number;
  focus: CameraFocus;
  durationFrames?: number;
};

type CursorSample = { seconds: number; x: number; y: number } | { seconds: number; x: null; y: null };
export type CursorTrack = { samplesPerSecond: number; samples: CursorSample[] };

const centerFocus = { x: 0.5, y: 0.5 };
// The follow camera averages the triangle's position over this window, so it glides instead of jittering.
const cursorSmoothingSeconds = 0.6;
// During a hold the frame drifts in by 8%, eased in and out across the hold, so a recording never looks frozen.
// A hold shorter than 5 seconds drifts less, so a short one never rushes.
const kenBurnsGrowth = 0.08;
const kenBurnsFullGrowthSeconds = 5;

function kenBurnsFactor(holdStartSeconds: number, holdEndSeconds: number, shotSeconds: number): number {
  const holdSeconds = holdEndSeconds - holdStartSeconds;
  if (holdSeconds <= 0) return 1;
  const progress = interpolate(shotSeconds, [holdStartSeconds, holdEndSeconds], [0, 1], {
    easing: cameraEase,
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  return 1 + kenBurnsGrowth * Math.min(1, holdSeconds / kenBurnsFullGrowthSeconds) * progress;
}

function cursorFocusAt(track: CursorTrack | undefined, sourceSeconds: number): { x: number; y: number } | null {
  if (!track) return null;
  const nearbySamples = track.samples.filter(
    (sample): sample is { seconds: number; x: number; y: number } =>
      sample.x !== null && Math.abs(sample.seconds - sourceSeconds) <= cursorSmoothingSeconds,
  );
  if (nearbySamples.length > 0) {
    // Nearer samples count more, which keeps the glide smooth without lagging far behind.
    let weightSum = 0, weightedX = 0, weightedY = 0;
    for (const sample of nearbySamples) {
      const weight = 1 - Math.abs(sample.seconds - sourceSeconds) / (cursorSmoothingSeconds + 0.01);
      weightSum += weight; weightedX += sample.x * weight; weightedY += sample.y * weight;
    }
    return { x: weightedX / weightSum, y: weightedY / weightSum };
  }
  const earlierSample = [...track.samples].reverse().find(
    (sample): sample is { seconds: number; x: number; y: number } => sample.x !== null && sample.seconds < sourceSeconds && sourceSeconds - sample.seconds < 3,
  );
  return earlierSample ? { x: earlierSample.x, y: earlierSample.y } : null;
}

// Clicky's speech bubble sits below and right of the triangle, so following the cursor frames the triangle and the
// bubble together, close enough to read the words it types.
const bubbleOffsetFromTriangle = { x: 0.06, y: 0.025 };

function resolvedFocus(focus: CameraFocus, track: CursorTrack | undefined, sourceSeconds: number, fallback: { x: number; y: number }) {
  if (focus !== "cursor") return focus;
  const triangle = cursorFocusAt(track, sourceSeconds);
  return triangle ? { x: triangle.x + bubbleOffsetFromTriangle.x, y: triangle.y + bubbleOffsetFromTriangle.y } : fallback;
}

/**
 * The camera's scale and focus at `shotSeconds` into a shot of `shotDurationSeconds` whose recording starts at
 * `sourceStartSeconds`.
 */
export function cameraAt(moves: CameraMove[], shotSeconds: number, shotDurationSeconds: number, sourceStartSeconds: number, track?: CursorTrack) {
  let scale = 1;
  let focus = centerFocus;
  let settledAtSeconds = 0;
  for (const move of moves) {
    if (move.atSeconds > shotSeconds) break;
    // The hold before this move drifted in, and the move starts from where the drift ended.
    scale *= kenBurnsFactor(settledAtSeconds, move.atSeconds, move.atSeconds);
    const moveSeconds = (move.durationFrames ?? punchInFrames) / frameRate;
    const progress = interpolate(shotSeconds, [move.atSeconds, move.atSeconds + moveSeconds], [0, 1], {
      easing: cameraEase,
      extrapolateLeft: "clamp",
      extrapolateRight: "clamp",
    });
    const targetFocus = resolvedFocus(move.focus, track, sourceStartSeconds + shotSeconds, focus);
    // #028 Zoom in grows the focal length exponentially, so each frame of the punch-in enlarges by the same ratio.
    scale = scale * Math.pow(move.scale / scale, progress);
    focus = { x: focus.x + (targetFocus.x - focus.x) * progress, y: focus.y + (targetFocus.y - focus.y) * progress };
    settledAtSeconds = move.atSeconds + moveSeconds;
  }
  const holdEndSeconds = moves.find((move) => move.atSeconds > shotSeconds)?.atSeconds ?? shotDurationSeconds;
  return { scale: scale * kenBurnsFactor(settledAtSeconds, holdEndSeconds, shotSeconds), focus };
}

// Each recording starts at the top of the demo Chrome window, whose tabs and URL bar fill the top 174 of 1924 rows.
// At the bottom, Chrome shows a hovered link's address in a box about 40 rows tall. The camera never shows either
// strip, with a little margin.
const browserToolbarShare = 0.092;
const linkAddressBoxShare = 0.026;
const pageShareOfHeight = 1 - browserToolbarShare - linkAddressBoxShare;

/**
 * A CSS transform that scales the recording about the focus and keeps the frame covered by the page between Chrome's
 * toolbar and its link address box. A scale of 1 fills the frame with that page area, so every scale is applied on
 * top of the crop.
 */
export function cameraTransform(scale: number, focus: { x: number; y: number }, width: number, height: number): string {
  const clamp = (value: number, lowest: number, highest: number) => Math.min(highest, Math.max(lowest, value));
  const pageScale = scale / pageShareOfHeight;
  const translateX = clamp(width / 2 - pageScale * focus.x * width, width - pageScale * width, 0);
  const translateY = clamp(
    height / 2 - pageScale * focus.y * height,
    height - pageScale * (1 - linkAddressBoxShare) * height,
    -pageScale * browserToolbarShare * height,
  );
  return `translate(${translateX}px, ${translateY}px) scale(${pageScale})`;
}
