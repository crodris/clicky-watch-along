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

// The study guide clip: a Notion study guide written in the background while a jet engine video plays. The YouTube
// video plays muted, so only Clicky's two short lines and the music are heard.
// The YouTube player fills about 78% of the frame's width, right of Chrome's tab sidebar, so 1.28 times fills it.
const engineVideo = { x: 0.57, y: 0.49 };
const engineVideoScale = 1.28;
// The chips and the agent list open just below and right of the blue triangle, which rests at about (0.67, 0.69).
const studyGuideChip = { x: 0.72, y: 0.73 };
const notionPage = { x: 0.64, y: 0.55 };
// Close enough to see the helper triangle trail the blue one and fill.
const helperScale = 3.0;
// The (0:23) timestamp link the driver clicks, near the middle of the scrolled page.
const timestampLink = { x: 0.55, y: 0.55 };
// The check mark on a finished helper (DS.Colors.success in the app).
const finishedCheckGreen = "#34D399";

export const studyGuideClipSegments: Segment[] = [
  {
    // The finished page first, so the result shows before anyone decides to scroll. The page is on screen from 61.6.
    kind: "shot",
    name: "payoff",
    recordingFile: "study-guide.mov",
    cursorTrackFile: "study-guide.cursor.json",
    sourceStartSeconds: 63.4,
    durationSeconds: 2.2,
    cameraMoves: [{ atSeconds: 0, scale: 1.5, focus: notionPage, durationFrames: 1 }],
    captions: [{ fromSeconds: 0.1, toSeconds: 2.1, text: "This wrote itself while I watched", accentWords: ["wrote itself"] }],
  },
  {
    // study-guide.events.txt: the request at 5.78, make_study_guide at 7.44, when the helper appears, and Clicky says
    // "Writing your study guide now. One moment." from 8.28 to 10.59.
    kind: "shot",
    name: "ask",
    recordingFile: "study-guide.mov",
    cursorTrackFile: "study-guide.cursor.json",
    sourceStartSeconds: 3.45,
    durationSeconds: 7.6,
    cameraMoves: [
      { atSeconds: 0, scale: engineVideoScale, focus: engineVideo, durationFrames: 1 },
      { atSeconds: 4.3, scale: labelScale, focus: studyGuideChip, durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.2, toSeconds: 2.1, text: "Watching something worth remembering?" },
      { fromSeconds: 2.3, toSeconds: 4.6, text: "Make me a Notion study guide for this video", voice: "learner" },
      { fromSeconds: 4.85, toSeconds: 7.5, text: "Writing your study guide now. One moment.", voice: "clicky" },
    ],
  },
  {
    // "Pop this out" at 12.88, Clicky says "Sure, let me pop that out." from 15.01 to 16.68, the engine lifts out at
    // 18.04, and the guide is written at 20.17, mid-tour: the helper fills, gets its green check, and the chip shows.
    kind: "shot",
    name: "popout",
    recordingFile: "study-guide.mov",
    cursorTrackFile: "study-guide.cursor.json",
    sourceStartSeconds: 12.6,
    durationSeconds: 11.2,
    cameraMoves: [
      { atSeconds: 0, scale: engineVideoScale, focus: engineVideo, durationFrames: 1 },
      { atSeconds: 7.0, scale: labelScale, focus: studyGuideChip, durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.3, toSeconds: 2.1, text: "Pop this out", voice: "learner" },
      { fromSeconds: 2.4, toSeconds: 4.1, text: "Sure, let me pop that out.", voice: "clicky" },
      { fromSeconds: 4.4, toSeconds: 7.3, text: "You keep learning while the helper writes", accentWords: ["keep learning"] },
      { fromSeconds: 7.6, toSeconds: 11.1, text: "It finishes mid-tour with a green check", accentWords: ["green check"], accentColor: finishedCheckGreen },
    ],
  },
  {
    // Clicky narrates the parts from 23.57, and the blue cursor flies to each label as it names it.
    kind: "shot",
    name: "narration",
    recordingFile: "study-guide.mov",
    cursorTrackFile: "study-guide.cursor.json",
    sourceStartSeconds: 23.4,
    durationSeconds: 5.6,
    cameraMoves: [{ atSeconds: 0, scale: engineVideoScale, focus: engineVideo, durationFrames: 1 }],
    captions: [
      { fromSeconds: 0.2, toSeconds: 5.5, text: "These small blades squeeze the air tighter and tighter", voice: "clicky" },
    ],
  },
  {
    // "Open my study guide" at 59.48, Clicky says "Opening your study guide now." from 62.13 to 63.79, the page shows from
    // 61.6, it scrolls to a point about the compressor from 65.5, and the mouse glides to its (0:23) link and clicks at
    // about 70.5. The shot ends on the click, since the new tab is blank until the video shows at 73.
    kind: "shot",
    name: "open",
    recordingFile: "study-guide.mov",
    cursorTrackFile: "study-guide.cursor.json",
    sourceStartSeconds: 59.1,
    durationSeconds: 11.9,
    cameraMoves: [
      { atSeconds: 0, scale: engineVideoScale, focus: engineVideo, durationFrames: 1 },
      { atSeconds: 3.0, scale: 1.5, focus: notionPage, durationFrames: bigMoveFrames },
      { atSeconds: 8.6, scale: 2.0, focus: timestampLink, durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.4, toSeconds: 2.6, text: "Open my study guide", voice: "learner" },
      { fromSeconds: 3.0, toSeconds: 4.8, text: "Opening your study guide now.", voice: "clicky" },
      { fromSeconds: 5.1, toSeconds: 11.6, text: "Every point links back to its moment in the video", accentWords: ["its moment"] },
    ],
  },
  {
    // The clicked link opens the video at 0:23, where it says "core", from 73.0 in the new tab.
    kind: "shot",
    name: "jump",
    recordingFile: "study-guide.mov",
    cursorTrackFile: "study-guide.cursor.json",
    sourceStartSeconds: 72.9,
    durationSeconds: 5.0,
    cameraMoves: [{ atSeconds: 0, scale: engineVideoScale, focus: engineVideo, durationFrames: 1 }],
    captions: [{ fromSeconds: 0.3, toSeconds: 4.8, text: "Click one, and the video jumps right there", accentWords: ["jumps right there"] }],
  },
  // The music fades out under this card.
  { kind: "endCard", name: "end-card", recordingFile: "study-guide.mov", sourceStartSeconds: 78, durationSeconds: 4.0 },
];

// The quiz miss clip, posted beside the study guide clip: one wrong answer lands at the top of the guide.
// quiz-miss.events.txt has a 4 minute wait between the wrong and the right answer, which the cuts skip.
// The quiz's "?" label, and the green name that replaces it, sit at the upper left of the lifted engine.
const quizQuestionLabel = { x: 0.3, y: 0.38 };
// "Review these first" sits just under the page's summary.
const reviewTheseFirst = { x: 0.6, y: 0.56 };

export const quizMissClipSegments: Segment[] = [
  {
    kind: "shot",
    name: "payoff",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 371.0,
    durationSeconds: 2.4,
    cameraMoves: [{ atSeconds: 0, scale: 1.7, focus: reviewTheseFirst, durationFrames: 1 }],
    captions: [{ fromSeconds: 0.1, toSeconds: 2.3, text: "My notes start with what I got wrong", accentWords: ["what I got wrong"] }],
  },
  {
    // "Watch this video with me and quiz me" at 5.70, and Clicky says "Sure, let me read through this video." from 6.77.
    kind: "shot",
    name: "ask",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 5.3,
    durationSeconds: 4.0,
    cameraMoves: [{ atSeconds: 0, scale: engineVideoScale, focus: engineVideo, durationFrames: 1 }],
    captions: [
      { fromSeconds: 0.3, toSeconds: 1.4, text: "Watch this video with me and quiz me", voice: "learner" },
      { fromSeconds: 1.5, toSeconds: 3.9, text: "Sure, let me read through this video.", voice: "clicky" },
    ],
  },
  {
    // The video pauses at 49.67 and the engine lifts out, and Clicky asks from 55.56 to 62.19.
    kind: "shot",
    name: "question",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 49.2,
    durationSeconds: 13.3,
    cameraMoves: [
      { atSeconds: 0, scale: engineVideoScale, focus: engineVideo, durationFrames: 1 },
      { atSeconds: 7.4, scale: 2.0, focus: quizQuestionLabel, durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.5, toSeconds: 5.9, text: "It pauses at the right moment and lifts it out in 3D", accentWords: ["3D"] },
      { fromSeconds: 6.4, toSeconds: 7.7, text: "Let's pause here.", voice: "clicky" },
      { fromSeconds: 7.9, toSeconds: 10.4, text: "In a compressor stage, which part slows the swirling air", voice: "clicky" },
      { fromSeconds: 10.5, toSeconds: 13.2, text: "to raise its pressure?", voice: "clicky" },
    ],
  },
  {
    // "Is it the muffler" at 63.03, and Clicky answers from 65.41 while the "?" shakes once.
    kind: "shot",
    name: "wrong",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 62.6,
    durationSeconds: 7.2,
    cameraMoves: [{ atSeconds: 0, scale: 2.0, focus: quizQuestionLabel, durationFrames: 1 }],
    captions: [
      { fromSeconds: 0.4, toSeconds: 2.4, text: "Is it the muffler?", voice: "learner" },
      { fromSeconds: 2.8, toSeconds: 7.1, text: "Good guess, but a muffler isn't part of a compressor stage.", voice: "clicky" },
    ],
  },
  {
    // "Is it the stator vanes" at 327.70, and Clicky says "Yes, the stator vanes are the part you're after." from
    // 330.61 as the label turns green with a ring.
    kind: "shot",
    name: "right",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 327.3,
    durationSeconds: 6.9,
    cameraMoves: [{ atSeconds: 0, scale: 2.0, focus: quizQuestionLabel, durationFrames: 1 }],
    captions: [
      { fromSeconds: 0.4, toSeconds: 3.0, text: "Is it the stator vanes?", voice: "learner" },
      { fromSeconds: 3.3, toSeconds: 6.8, text: "Yes, the stator vanes are the part you're after.", voice: "clicky", accentWords: ["stator vanes"], accentColor: finishedCheckGreen },
    ],
  },
  {
    // "Make me a Notion study guide for this video" at 344.29, and Clicky says "On it, writing your study guide." from 346.18.
    kind: "shot",
    name: "guide",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 343.9,
    durationSeconds: 4.8,
    cameraMoves: [{ atSeconds: 0, scale: engineVideoScale, focus: engineVideo, durationFrames: 1 }],
    captions: [
      { fromSeconds: 0.3, toSeconds: 2.1, text: "Make me a Notion study guide for this video", voice: "learner" },
      { fromSeconds: 2.3, toSeconds: 4.7, text: "On it, writing your study guide.", voice: "clicky" },
    ],
  },
  {
    // "Open my study guide" at 364.72, the page shows from about 366.7, and Clicky says "There! Opening your study
    // guide!" from 367.24.
    kind: "shot",
    name: "open",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 364.4,
    durationSeconds: 10.4,
    cameraMoves: [
      { atSeconds: 0, scale: engineVideoScale, focus: engineVideo, durationFrames: 1 },
      { atSeconds: 4.6, scale: 1.7, focus: reviewTheseFirst, durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.3, toSeconds: 2.5, text: "Open my study guide", voice: "learner" },
      { fromSeconds: 2.8, toSeconds: 4.8, text: "There! Opening your study guide!", voice: "clicky" },
      { fromSeconds: 5.2, toSeconds: 10.2, text: "The question I missed comes first", accentWords: ["I missed"] },
    ],
  },
  // The music fades out under this card.
  { kind: "endCard", name: "end-card", recordingFile: "quiz-miss.mov", sourceStartSeconds: 378, durationSeconds: 4.0 },
];

// The landmark clip: "show me this in 3D" over a drone video of the Colosseum brings up Google's real 3D scan of it.
// The scan spills past the player, so its shots stay wide.
const dronePlayer = { x: 0.57, y: 0.49 };
const scanAroundThePlayer = { x: 0.5, y: 0.52 };

export const landmarkClipSegments: Segment[] = [
  {
    // landmark.events.txt: "show me this in 3D" at 5.93, and Clicky says "Sure, let me build that for you." from 9.91.
    kind: "shot",
    name: "ask",
    recordingFile: "landmark.mov",
    cursorTrackFile: "landmark.cursor.json",
    sourceStartSeconds: 3.2,
    durationSeconds: 9.4,
    cameraMoves: [{ atSeconds: 0, scale: engineVideoScale, focus: dronePlayer, durationFrames: 1 }],
    captions: [
      { fromSeconds: 0.2, toSeconds: 2.5, text: "Flying over Rome on YouTube?" },
      { fromSeconds: 2.7, toSeconds: 5.4, text: "Show me this in 3D", voice: "learner" },
      { fromSeconds: 6.7, toSeconds: 9.0, text: "Sure, let me build that for you.", voice: "clicky" },
    ],
  },
  {
    // The page starts at 12.28, and its tiles load and rise out of the video from about 15.5, then tour until about 23.
    kind: "shot",
    name: "rise",
    recordingFile: "landmark.mov",
    cursorTrackFile: "landmark.cursor.json",
    sourceStartSeconds: 14.8,
    durationSeconds: 8.9,
    cameraMoves: [{ atSeconds: 0, scale: 1.1, focus: scanAroundThePlayer, durationFrames: 1 }],
    captions: [
      { fromSeconds: 0.2, toSeconds: 3.8, text: "Clicky recognizes the Colosseum", accentWords: ["recognizes"] },
      { fromSeconds: 4.0, toSeconds: 8.7, text: "and pulls Google's real 3D scan out of the video", accentWords: ["real 3D scan"] },
    ],
  },
  {
    // Clicky says "This is Colosseum, in real 3D." from 23.85 and "It stands about 48 meters tall, as high as a 16-story
    // building." from 27.46 to 32.65.
    kind: "shot",
    name: "line",
    recordingFile: "landmark.mov",
    cursorTrackFile: "landmark.cursor.json",
    sourceStartSeconds: 23.6,
    durationSeconds: 9.4,
    cameraMoves: [{ atSeconds: 0, scale: 1.1, focus: scanAroundThePlayer, durationFrames: 1 }],
    captions: [
      { fromSeconds: 0.25, toSeconds: 3.5, text: "This is Colosseum, in real 3D.", voice: "clicky" },
      { fromSeconds: 3.8, toSeconds: 9.2, text: "It stands about 48 meters tall, as high as a 16-story building.", voice: "clicky" },
    ],
  },
  {
    // "Turn it to the left" at 34.83, "zoom in" at 40.39, and "put it back" at 45.36, each with Clicky's short reply,
    // and the scan flattens back into the video.
    kind: "shot",
    name: "voice",
    recordingFile: "landmark.mov",
    cursorTrackFile: "landmark.cursor.json",
    sourceStartSeconds: 34.5,
    durationSeconds: 14.2,
    cameraMoves: [{ atSeconds: 0, scale: 1.1, focus: scanAroundThePlayer, durationFrames: 1 }],
    captions: [
      { fromSeconds: 0.3, toSeconds: 2.1, text: "Turn it to the left", voice: "learner" },
      { fromSeconds: 2.2, toSeconds: 4.0, text: "There! Turned it left!", voice: "clicky" },
      { fromSeconds: 5.85, toSeconds: 7.2, text: "Zoom in", voice: "learner" },
      { fromSeconds: 7.3, toSeconds: 9.0, text: "Zooming in closer.", voice: "clicky" },
      { fromSeconds: 10.8, toSeconds: 11.35, text: "Put it back", voice: "learner" },
      { fromSeconds: 11.4, toSeconds: 13.9, text: "Okay, back to the video.", voice: "clicky" },
    ],
  },
  // The music fades out under this card.
  { kind: "endCard", name: "end-card", recordingFile: "landmark.mov", sourceStartSeconds: 50, durationSeconds: 4.0 },
];
