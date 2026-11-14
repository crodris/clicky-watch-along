// Motion Prompt #025-048 · MIT License (c) 2026 Shohei Ohtaki · https://showheyohtaki.github.io/motion-prompt/#025
// The easing helpers below are the motion kit's, and the moves in this edit are rebuilt from elements
// #028 Zoom in and #044 Cross dissolve.
import { Easing, interpolate } from "remotion";
import { loadFont as loadInter } from "@remotion/google-fonts/Inter";

export const frameRate = 30;
export const videoWidth = 1920;
export const videoHeight = 1080;

export const bodyFont = loadInter("normal", { weights: ["500", "600", "700"], subsets: ["latin"] }).fontFamily;

export const colors = {
  // Clicky's own blue, used only for its triangle glyph, never for text.
  clickyBlue: "#3380FF",
  // Warm yellow reads on the dark pill, where Clicky blue was hard to read.
  captionAccent: "#FFD447",
  pillFill: "rgba(10, 11, 15, 0.92)",
  pillBorder: "rgba(255, 255, 255, 0.10)",
  text: "#FFFFFF",
  background: "#0B0D12",
};

// Typography, captions, and cards ease out with no bounce.
export const softEase = Easing.out(Easing.cubic);
// Camera punch-ins ease in and out.
export const cameraEase = Easing.inOut(Easing.cubic);

export const typographyEnterFrames = 10;
export const typographyRisePixels = 16;
export const punchInFrames = 21;
export const dissolveFrames = 15;

export const seconds = (secondCount: number) => Math.round(secondCount * frameRate);

/** The motion kit's progress through [start, end], clamped to 0..1. */
export const progressBetween = (time: number, start: number, end: number) => Math.min(1, Math.max(0, (time - start) / (end - start)));
/** The motion kit's quadratic ease-in-out (eIOs). */
export const easeInOutQuadratic = (x: number) => (x < 0.5 ? 2 * x * x : 1 - Math.pow(-2 * x + 2, 2) / 2);

/** 0 to 1 over `durationFrames` from `startFrame`, eased softly. */
export function softProgress(frame: number, startFrame: number, durationFrames: number): number {
  return interpolate(frame, [startFrame, startFrame + durationFrames], [0, 1], {
    easing: softEase,
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
}
