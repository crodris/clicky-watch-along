import type { CameraMove } from "./camera.ts";
import type { Caption } from "./components.tsx";

/**
 * The edit, shot by shot. Every time is in seconds. A shot's `sourceStartSeconds` is where it starts in its
 * recording, and its captions and camera moves count from the start of the shot. The times come from the
 * recordings' `*.events.txt`, which stamp each app log line with seconds since the recording started.
 */
export type ShotSegment = {
  kind: "shot";
  name: string;
  recordingFile: string;
  cursorTrackFile?: string;
  sourceStartSeconds: number;
  durationSeconds: number;
  cameraMoves: CameraMove[];
  captions: Caption[];
};

/** The closing card over a blurred, muted stretch of a recording. */
export type EndCardSegment = { kind: "endCard"; name: string; recordingFile: string; sourceStartSeconds: number; durationSeconds: number };

export type Segment = ShotSegment | EndCardSegment;

// Points in each recording, as a share of the 16:9 frame. The mouse rested left of the status labels and tool chips,
// so they sit just right of it, and the camera reads them at about 2.8 times.
const volcanoInTheVideo = { x: 0.5, y: 0.5 };
const volcanoStatusLabel = { x: 0.71, y: 0.66 };
const volcanoChip = { x: 0.7, y: 0.7 };
const printOnThePage = { x: 0.46, y: 0.63 };
const printStatusLabel = { x: 0.71, y: 0.58 };
const labelScale = 2.8;
// Close enough to read the words Clicky types beside the cursor on a phone.
const bubbleScale = 3.2;
const bigMoveFrames = 27;
// The zoom onto Clicky's speech bubble is the largest move, about 3 times, so it takes longer to stay gentle.
const bubbleMoveFrames = 40;

export const segments: Segment[] = [
  {
    // volcano.events.txt: the request at 5.61, find_moment's chip from about 6.8 to 9.25, seek_to_time at 10.24,
    // and Clicky says "Found the crater. Jumping there." from 11.15 to 13.04.
    kind: "shot",
    name: "seek",
    recordingFile: "volcano.mov",
    cursorTrackFile: "volcano.cursor.json",
    sourceStartSeconds: 3.3,
    durationSeconds: 11.8,
    cameraMoves: [
      { atSeconds: 0, scale: 1.04, focus: volcanoInTheVideo, durationFrames: 1 },
      { atSeconds: 3.3, scale: labelScale, focus: volcanoChip, durationFrames: bigMoveFrames },
      { atSeconds: 8.6, scale: 1.06, focus: volcanoInTheVideo, durationFrames: bigMoveFrames },
    ],
    captions: [
      // The video opens on the action, so one line says what this is before the first request.
      { fromSeconds: 0.15, toSeconds: 1.75, text: "Clicky, watching along with you" },
      { fromSeconds: 1.95, toSeconds: 3.3, text: "Skip to where they talk about the crater", voice: "learner" },
      { fromSeconds: 4.3, toSeconds: 6.7, text: "Clicky searches the video's captions", accentWords: ["captions"] },
      { fromSeconds: 7.75, toSeconds: 10.4, text: "Found the crater. Jumping there.", voice: "clicky" },
    ],
  },
  {
    // The request at 15.24, pop_out at 16.56, the subject lifting at 20.14.
    kind: "shot",
    name: "pop-out",
    recordingFile: "volcano.mov",
    cursorTrackFile: "volcano.cursor.json",
    sourceStartSeconds: 14.2,
    durationSeconds: 11.2,
    cameraMoves: [
      { atSeconds: 0, scale: 1.06, focus: volcanoInTheVideo, durationFrames: 1 },
      { atSeconds: 2.3, scale: labelScale, focus: volcanoStatusLabel, durationFrames: bigMoveFrames },
      { atSeconds: 5.2, scale: 1.04, focus: volcanoInTheVideo, durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.3, toSeconds: 2.2, text: "Pop this out", voice: "learner" },
      { fromSeconds: 3.2, toSeconds: 5.1, text: "Clicky finds the subject in the paused frame" },
      { fromSeconds: 6.0, toSeconds: 11.0, text: "and lifts it out of the video in 3D", accentWords: ["3D"] },
    ],
  },
  {
    // The magma chamber sentence plays from 33.42 to 41.29, and the next one starts at 42.37, so the shot ends in
    // the pause between them.
    kind: "shot",
    name: "narration",
    recordingFile: "volcano.mov",
    cursorTrackFile: "volcano.cursor.json",
    sourceStartSeconds: 32.9,
    durationSeconds: 9.0,
    cameraMoves: [
      { atSeconds: 0, scale: 1.05, focus: volcanoInTheVideo, durationFrames: 1 },
      // The triangle reaches the magma chamber at about 35.8, so the camera waits for it there.
      { atSeconds: 2.9, scale: bubbleScale, focus: "cursor", durationFrames: bubbleMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.5, toSeconds: 4.6, text: "Then it explains each part out loud", accentWords: ["explains"] },
      { fromSeconds: 4.9, toSeconds: 8.8, text: "and points at the part it's talking about", accentWords: ["points"] },
    ],
  },
  {
    // "Animate this" at 64.61, the "Animating it" label until the flows start at 70.28.
    kind: "shot",
    name: "animate",
    recordingFile: "volcano.mov",
    cursorTrackFile: "volcano.cursor.json",
    sourceStartSeconds: 64.2,
    durationSeconds: 13.3,
    cameraMoves: [
      { atSeconds: 0, scale: 1.06, focus: volcanoInTheVideo, durationFrames: 1 },
      { atSeconds: 1.2, scale: labelScale, focus: volcanoStatusLabel, durationFrames: bigMoveFrames },
      { atSeconds: 5.4, scale: 1.15, focus: { x: 0.5, y: 0.45 }, durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.3, toSeconds: 2.6, text: "Animate this", voice: "learner" },
      { fromSeconds: 2.9, toSeconds: 5.3, text: "Clicky works out what flows through it" },
      { fromSeconds: 6.6, toSeconds: 13.1, text: "Lava rises and ash drifts over the picture", accentWords: ["Lava", "ash"] },
    ],
  },
  {
    // ejiri.events.txt: the request at 5.63, the status label until the whole print lifts at 10.12.
    kind: "shot",
    name: "artwork",
    recordingFile: "ejiri.mov",
    cursorTrackFile: "ejiri.cursor.json",
    sourceStartSeconds: 3.6,
    durationSeconds: 11.3,
    cameraMoves: [
      { atSeconds: 0, scale: 1.04, focus: printOnThePage, durationFrames: 1 },
      { atSeconds: 2.9, scale: labelScale, focus: printStatusLabel, durationFrames: bigMoveFrames },
      { atSeconds: 5.8, scale: 1.05, focus: printOnThePage, durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.5, toSeconds: 1.9, text: "It works on any picture, too", accentWords: ["any picture"] },
      { fromSeconds: 2.05, toSeconds: 4.1, text: "Pop this out", voice: "learner" },
      { fromSeconds: 6.8, toSeconds: 11.1, text: "On a painting or print, the whole picture lifts out" },
    ],
  },
  {
    // The first sentence plays from 15.73 to 27.02, with the triangle on Mount Fuji from about 17.5. The next one
    // starts at 28.21, so the shot ends in the pause between them.
    kind: "shot",
    name: "artwork-story",
    recordingFile: "ejiri.mov",
    cursorTrackFile: "ejiri.cursor.json",
    sourceStartSeconds: 15.4,
    durationSeconds: 12.3,
    cameraMoves: [
      { atSeconds: 0, scale: 1.08, focus: printOnThePage, durationFrames: 1 },
      { atSeconds: 2.2, scale: bubbleScale, focus: "cursor", durationFrames: bubbleMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.5, toSeconds: 5.0, text: "On art, Clicky tells the story behind it", accentWords: ["story"] },
      { fromSeconds: 5.3, toSeconds: 8.9, text: "Hokusai's Ejiri in Suruga Province", accentWords: ["Hokusai's"] },
      { fromSeconds: 9.2, toSeconds: 12.1, text: "from Thirty-six Views of Mount Fuji", accentWords: ["Thirty-six Views of Mount Fuji"] },
    ],
  },
  {
    // The narration ends at 49.69, "Animate this" comes at 51.67, and Clicky says "This is a work of art," from
    // 52.17 to 53.84 and "so I'll leave it just as the artist made it." from 54.19 to 56.97.
    kind: "shot",
    name: "artwork-refusal",
    recordingFile: "ejiri.mov",
    cursorTrackFile: "ejiri.cursor.json",
    sourceStartSeconds: 49.9,
    durationSeconds: 8.0,
    cameraMoves: [
      { atSeconds: 0, scale: 1.08, focus: printOnThePage, durationFrames: 1 },
    ],
    captions: [
      { fromSeconds: 0.6, toSeconds: 2.1, text: "Animate this", voice: "learner" },
      { fromSeconds: 2.25, toSeconds: 4.1, text: "This is a work of art,", voice: "clicky" },
      { fromSeconds: 4.25, toSeconds: 7.7, text: "so I'll leave it just as the artist made it.", voice: "clicky" },
    ],
  },
  // The music fades out under this card.
  { kind: "endCard", name: "end-card", recordingFile: "ejiri.mov", sourceStartSeconds: 58, durationSeconds: 4.0 },
];

// The follow-up clip: a quiz on a facial nerve video, then a moving picture that keeps moving.
const nerveVideo = { x: 0.5, y: 0.5 };
const nerveStatusLabel = { x: 0.55, y: 0.58 };
const nerveHiddenHeading = { x: 0.3, y: 0.3 };
const nerveQuestionMark = { x: 0.66, y: 0.62 };
const globePage = { x: 0.46, y: 0.6 };
const globeStatusLabel = { x: 0.71, y: 0.575 };
const liftedGlobe = { x: 0.5, y: 0.55 };

export const quizClipSegments: Segment[] = [
  {
    // nerve-quiz.events.txt: a YouTube ad played until about 13 s, and Clicky planned the questions until 22.95.
    kind: "shot",
    name: "quiz-start",
    recordingFile: "nerve-quiz.mov",
    sourceStartSeconds: 12.8,
    durationSeconds: 7.0,
    cameraMoves: [
      { atSeconds: 0, scale: 1.04, focus: nerveVideo, durationFrames: 1 },
      { atSeconds: 1.0, scale: labelScale, focus: nerveStatusLabel, durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.3, toSeconds: 2.6, text: "Watch this video with me and quiz me", voice: "learner" },
      { fromSeconds: 2.9, toSeconds: 6.8, text: "Clicky reads the captions and picks spots to quiz you on", accentWords: ["quiz"] },
    ],
  },
  {
    // The pause and lift at 36.74, the question from 43.48 to 49.97, the answer at 50.50, and Clicky's
    // confirmation from 52.31 to 56.18, before its follow-up starts at 56.54.
    kind: "shot",
    name: "quiz-question",
    recordingFile: "nerve-quiz.mov",
    sourceStartSeconds: 34.5,
    durationSeconds: 21.9,
    cameraMoves: [
      { atSeconds: 0, scale: 1.04, focus: nerveVideo, durationFrames: 1 },
      { atSeconds: 13.2, scale: 2.0, focus: nerveHiddenHeading, durationFrames: bigMoveFrames },
      { atSeconds: 15.7, scale: 2.0, focus: nerveQuestionMark, durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 2.4, toSeconds: 7.2, text: "It pauses and lifts the drawing out in 3D", accentWords: ["3D"] },
      { fromSeconds: 8.9, toSeconds: 13.0, text: "Through which opening does the facial nerve leave the skull?", voice: "clicky" },
      { fromSeconds: 13.3, toSeconds: 15.8, text: "The video's own labels are blurred so they can't give it away", accentWords: ["blurred"] },
      { fromSeconds: 16.0, toSeconds: 17.6, text: "Is it the stylomastoid foramen?", voice: "learner" },
      { fromSeconds: 17.8, toSeconds: 21.7, text: "Yes, the stylomastoid foramen is the right name.", voice: "clicky" },
    ],
  },
  {
    // earth.events.txt: "pop this out" at 5.82, the lift at 11.05, and "This is Earth spinning," from 16.45 to 17.92,
    // then "and it turns all the way around once every day." until 21.50.
    kind: "shot",
    name: "moving-picture",
    recordingFile: "earth.mov",
    sourceStartSeconds: 5.4,
    durationSeconds: 16.45,
    cameraMoves: [
      { atSeconds: 0, scale: 1.04, focus: globePage, durationFrames: 1 },
      { atSeconds: 1.6, scale: labelScale, focus: globeStatusLabel, durationFrames: bigMoveFrames },
      { atSeconds: 4.9, scale: 1.15, focus: liftedGlobe, durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.3, toSeconds: 2.4, text: "Pop this out", voice: "learner" },
      { fromSeconds: 6.0, toSeconds: 10.7, text: "Moving pictures keep moving", accentWords: ["keep moving"] },
      { fromSeconds: 11.0, toSeconds: 12.8, text: "This is Earth spinning,", voice: "clicky" },
      { fromSeconds: 12.95, toSeconds: 16.3, text: "and it turns all the way around once every day.", voice: "clicky" },
    ],
  },
  { kind: "endCard", name: "end-card", recordingFile: "earth.mov", sourceStartSeconds: 30, durationSeconds: 4.0 },
];
