import { loadFont as loadFraunces } from "@remotion/google-fonts/Fraunces";
import { loadFont as loadSpaceGrotesk } from "@remotion/google-fonts/SpaceGrotesk";
import { bodyFont, colors } from "./motion.ts";

/**
 * How one clip looks: the caption card, the accent on key words, and the end card. Each clip gets its own theme, so
 * the reels share a template but not a feel.
 */
export type DemoTheme = {
  captionFont: string;
  captionText: string;
  captionFill: string;
  captionBorder: string;
  captionCornerRadius: number;
  /** "text" colors accent words; "highlighter" sweeps a marker stroke behind them, left to right, as the caption enters. */
  accent: { style: "text" | "highlighter"; color: string };
  /** The learner's mic glyph. */
  micColor: string;
  endCard: { title: string; tagline?: string; handle: string; titleColor: string; handleColor: string; scrim: string };
};

export const watchAlongTheme: DemoTheme = {
  captionFont: bodyFont,
  captionText: colors.text,
  captionFill: colors.pillFill,
  captionBorder: colors.pillBorder,
  captionCornerRadius: 999,
  accent: { style: "text", color: colors.captionAccent },
  micColor: colors.captionAccent,
  endCard: { title: "Clicky watch-along", handle: "@HayloCR", titleColor: colors.text, handleColor: colors.captionAccent, scrim: "rgba(10, 11, 15, 0.62)" },
};

const notebookSerif = loadFraunces("normal", { weights: ["500", "600", "700"], subsets: ["latin"] }).fontFamily;
// The study guide wingman's amber (DS.Colors.backgroundAgentStudyGuideAmber in the app).
const studyGuideAmber = "#FFB020";
const notebookInk = "#1C1B19";

/** A paper card with ink serif type, and an amber highlighter over key words, like notes taken while watching. */
export const studyGuideTheme: DemoTheme = {
  captionFont: notebookSerif,
  captionText: notebookInk,
  captionFill: "rgba(250, 246, 237, 0.97)",
  captionBorder: "rgba(28, 27, 25, 0.12)",
  captionCornerRadius: 18,
  accent: { style: "highlighter", color: studyGuideAmber },
  micColor: notebookInk,
  endCard: {
    title: "Clicky watch-along",
    tagline: "Notes that write themselves while you watch",
    handle: "@HayloCR",
    titleColor: "#FAF6ED",
    handleColor: studyGuideAmber,
    scrim: "rgba(18, 16, 12, 0.66)",
  },
};

/** The quiz miss clip posts beside the study guide clip, so it keeps the notebook look with its own end card line. */
export const quizMissTheme: DemoTheme = {
  ...studyGuideTheme,
  endCard: { ...studyGuideTheme.endCard, tagline: "Notes that remember what you missed" },
};

const travelSans = loadSpaceGrotesk("normal", { weights: ["500", "600", "700"], subsets: ["latin"] }).fontFamily;
const skyTeal = "#5EEAD4";

/** A dark map-like card with teal words, for the landmark clip's aerial footage and its 3D scan. */
export const landmarkTheme: DemoTheme = {
  captionFont: travelSans,
  captionText: "#F1F5F9",
  captionFill: "rgba(15, 23, 42, 0.88)",
  captionBorder: "rgba(94, 234, 212, 0.35)",
  captionCornerRadius: 10,
  accent: { style: "text", color: skyTeal },
  micColor: skyTeal,
  endCard: {
    title: "Clicky watch-along",
    tagline: "Step into the places you watch",
    handle: "@HayloCR",
    titleColor: "#F1F5F9",
    handleColor: skyTeal,
    scrim: "rgba(8, 13, 26, 0.66)",
  },
};
