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
  /** For a shot from later in the recording, such as an opening glimpse of the result, whose sound would be out of place. */
  muted?: boolean;
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
// Frames the key terms at the bottom of the page, with the (1:05) link the driver clicks.
const keyTermLink = { x: 0.6, y: 0.5 };
// The check mark on a finished helper (DS.Colors.success in the app).
const finishedCheckGreen = "#34D399";

// Clicky's own lines are heard, so only the learner's silent requests and what is happening get captions. The captions
// name the parts the way an engineer would, since the clip is for people who build agents.
export const studyGuideClipSegments: Segment[] = [
  {
    // study-guide.events.txt: the request at 5.67, make_study_guide spawns the helper at 7.20, which shows "Reading the
    // captions" until 10.22 and then "Writing the guide in Notion", and the mouse glides out from 8.0 and back by 11.4
    // with the helper trailing. Clicky says "On it, writing your study guide." from 7.62 to 9.71.
    kind: "shot",
    name: "ask",
    recordingFile: "study-guide.mov",
    cursorTrackFile: "study-guide.cursor.json",
    sourceStartSeconds: 3.4,
    durationSeconds: 8.6,
    cameraMoves: [
      { atSeconds: 0, scale: engineVideoScale, focus: engineVideo, durationFrames: 1 },
      { atSeconds: 3.7, scale: helperScale, focus: "cursor", durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.2, toSeconds: 2.1, text: "Watching something worth remembering?" },
      { fromSeconds: 2.3, toSeconds: 4.3, text: "Make me a Notion study guide for this video", voice: "learner" },
      { fromSeconds: 4.4, toSeconds: 6.2, text: "The tool call spawns a background sub-agent", accentWords: ["sub-agent"] },
      { fromSeconds: 6.3, toSeconds: 8.4, text: "It trails your cursor and shows the step it's on", accentWords: ["step it's on"] },
    ],
  },
  {
    // Starts where the ask's last dissolve begins. "Pop this out" at 11.80, the agent list is open from about 13.5 to
    // 17.5 while the pop-out builds, the engine lifts out at 16.37, and the guide is written at 19.77: the helper fills,
    // gets its green check, and the chip shows.
    kind: "shot",
    name: "popout",
    recordingFile: "study-guide.mov",
    cursorTrackFile: "study-guide.cursor.json",
    sourceStartSeconds: 11.5,
    durationSeconds: 10.4,
    cameraMoves: [
      { atSeconds: 0, scale: engineVideoScale, focus: engineVideo, durationFrames: 1 },
      { atSeconds: 1.7, scale: labelScale, focus: studyGuideChip, durationFrames: bigMoveFrames },
      { atSeconds: 5.8, scale: engineVideoScale, focus: engineVideo, durationFrames: bigMoveFrames },
      { atSeconds: 7.8, scale: labelScale, focus: studyGuideChip, durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.3, toSeconds: 2.0, text: "Pop this out", voice: "learner" },
      { fromSeconds: 2.2, toSeconds: 5.8, text: "Shift + option lists every running sub-agent", accentWords: ["shift + option"] },
      { fromSeconds: 6.0, toSeconds: 8.1, text: "The main agent stays free for you", accentWords: ["stays free"] },
      { fromSeconds: 8.3, toSeconds: 10.3, text: "Done: green check, page ready in a background tab", accentWords: ["green check"], accentColor: finishedCheckGreen },
    ],
  },
  {
    // Starts where the pop-out's last dissolve begins. Clicky's first sentence runs from 21.70 to 29.71, and the shot
    // ends in the pause after it.
    kind: "shot",
    name: "narration",
    recordingFile: "study-guide.mov",
    cursorTrackFile: "study-guide.cursor.json",
    sourceStartSeconds: 21.4,
    durationSeconds: 8.6,
    cameraMoves: [{ atSeconds: 0, scale: engineVideoScale, focus: engineVideo, durationFrames: 1 }],
    captions: [],
  },
  {
    // "Open my study guide" at 64.63, the page shows from about 66.5, Clicky says "Opening your study guide now!" from
    // 66.86, the page scrolls to its key terms from 70.6, and the mouse glides to the (1:05) link of a key term and
    // clicks at about 79.2. The shot ends on the click, since the new tab is blank until the video shows.
    kind: "shot",
    name: "open",
    recordingFile: "study-guide.mov",
    cursorTrackFile: "study-guide.cursor.json",
    sourceStartSeconds: 64.4,
    durationSeconds: 15.0,
    cameraMoves: [
      { atSeconds: 0, scale: engineVideoScale, focus: engineVideo, durationFrames: 1 },
      { atSeconds: 2.4, scale: 1.5, focus: notionPage, durationFrames: bigMoveFrames },
      { atSeconds: 7.4, scale: 1.6, focus: keyTermLink, durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.2, toSeconds: 2.4, text: "Open my study guide", voice: "learner" },
      { fromSeconds: 4.4, toSeconds: 8.9, text: "Every point links back to its moment in the video", accentWords: ["its moment"] },
      { fromSeconds: 9.1, toSeconds: 14.8, text: "The key terms link back too", accentWords: ["key terms"] },
    ],
  },
  {
    // The clicked link opens the video at 1:05 in a new tab, where it plays from about 82.
    kind: "shot",
    name: "jump",
    recordingFile: "study-guide.mov",
    cursorTrackFile: "study-guide.cursor.json",
    sourceStartSeconds: 81.9,
    durationSeconds: 4.6,
    cameraMoves: [{ atSeconds: 0, scale: engineVideoScale, focus: engineVideo, durationFrames: 1 }],
    captions: [{ fromSeconds: 0.3, toSeconds: 4.4, text: "Click one, and the video jumps right there", accentWords: ["jumps right there"] }],
  },
  // The music fades out under this card.
  { kind: "endCard", name: "end-card", recordingFile: "study-guide.mov", sourceStartSeconds: 82, durationSeconds: 4.0 },
];

// The quiz miss clip, posted beside the study guide clip. The take writes the guide first, off camera, so the clip
// starts at the quiz: a missed question spawns an update sub-agent, and the guide opens with the miss at the top.
// The quiz's "?" label sits at the upper left of the lifted engine, with the question in the blue cursor's bubble.
const quizQuestionLabel = { x: 0.36, y: 0.4 };
// The update helper flies back with the blue cursor to the mouse, which rests at about (0.67, 0.69), and its chip opens
// just below and right of it, as in the study guide clip.
const quizUpdateHelper = studyGuideChip;
// "Review these first" sits just under the page's summary.
const reviewTheseFirst = { x: 0.6, y: 0.56 };

export const quizMissClipSegments: Segment[] = [
  {
    // quiz-miss.events.txt: "Watch this video with me and quiz me" at 24.59, and Clicky says "Sure, let me read through
    // this video." from 25.29.
    kind: "shot",
    name: "ask",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 24.2,
    durationSeconds: 3.6,
    cameraMoves: [{ atSeconds: 0, scale: engineVideoScale, focus: engineVideo, durationFrames: 1 }],
    captions: [{ fromSeconds: 0.3, toSeconds: 3.4, text: "Watch this video with me and quiz me", voice: "learner" }],
  },
  {
    // The video pauses at 65.17 and the engine lifts out. Clicky asks from 70.48 to 77.27 while the blue cursor flies
    // to the "?" label and its bubble types the question.
    kind: "shot",
    name: "question",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 64.8,
    durationSeconds: 13.0,
    cameraMoves: [
      { atSeconds: 0, scale: engineVideoScale, focus: engineVideo, durationFrames: 1 },
      { atSeconds: 5.4, scale: 2.0, focus: quizQuestionLabel, durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.5, toSeconds: 5.3, text: "It pauses at the right moment and lifts it out in 3D", accentWords: ["3D"] },
      { fromSeconds: 6.0, toSeconds: 12.6, text: "The question stays in the cursor's bubble", accentWords: ["cursor's bubble"] },
    ],
  },
  {
    // Starts where the question's last dissolve begins. "Is it the muffler" at 77.50, and Clicky's first sentence runs
    // from 79.82 to the pause at 84.76, while the "?" shakes once and the question stays in the bubble.
    kind: "shot",
    name: "wrong",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 77.3,
    durationSeconds: 7.75,
    cameraMoves: [{ atSeconds: 0, scale: 2.0, focus: quizQuestionLabel, durationFrames: 1 }],
    captions: [{ fromSeconds: 0.2, toSeconds: 2.4, text: "Is it the muffler?", voice: "learner" }],
  },
  {
    // "Is it the stator vanes" at 93.73. The miss spawns the update helper at 95.62, which shows "Adding your miss to the
    // guide" and finishes at 96.54 with its check and the "Study guide updated" chip, while Clicky answers from 95.54.
    kind: "shot",
    name: "update",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 93.4,
    durationSeconds: 8.6,
    cameraMoves: [
      { atSeconds: 0, scale: 2.0, focus: quizQuestionLabel, durationFrames: 1 },
      // After the "?" turns green with its ring at about 2.1, which the camera stays on.
      { atSeconds: 3.0, scale: 2.4, focus: quizUpdateHelper, durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.3, toSeconds: 2.1, text: "Is it the stator vanes?", voice: "learner" },
      { fromSeconds: 2.3, toSeconds: 5.4, text: "The miss spawns a sub-agent that updates the guide", accentWords: ["sub-agent"] },
      { fromSeconds: 5.6, toSeconds: 8.4, text: "Done in under a second, with no model call", accentWords: ["under a second"], accentColor: finishedCheckGreen },
    ],
  },
  {
    // "Open my study guide" at 112.96, the page shows from about 115, and Clicky says "There! Opening your study guide!"
    // from 115.40.
    kind: "shot",
    name: "open",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 112.7,
    durationSeconds: 10.6,
    cameraMoves: [
      { atSeconds: 0, scale: engineVideoScale, focus: engineVideo, durationFrames: 1 },
      { atSeconds: 3.4, scale: 1.7, focus: reviewTheseFirst, durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.3, toSeconds: 2.4, text: "Open my study guide", voice: "learner" },
      { fromSeconds: 4.6, toSeconds: 10.4, text: "The miss is already at the top of the guide", accentWords: ["already at the top"] },
    ],
  },
  // The music fades out under this card.
  { kind: "endCard", name: "end-card", recordingFile: "quiz-miss.mov", sourceStartSeconds: 125, durationSeconds: 4.0 },
];

/** A shot from one of the clips above, found by name, so the combined clip reuses its times and captions. */
function shotNamed(clipSegments: Segment[], shotName: string): Segment {
  const shot = clipSegments.find((segment) => segment.name === shotName);
  if (!shot) throw new Error(`no shot named ${shotName}`);
  return shot;
}

// The study guide and quiz miss clips as one story for the HeyClicky team: the guide is written by a sub-agent, then a
// quiz miss spawns another that updates it, and the guide opens with the miss on top. The study guide take's key terms
// click closes it. The pop-out narration and the first take's own opening of the guide are left out.
export const subAgentsClipSegments: Segment[] = [
  { ...shotNamed(studyGuideClipSegments, "ask"), name: "guide-ask" },
  { ...shotNamed(studyGuideClipSegments, "popout"), name: "guide-popout" },
  { ...shotNamed(quizMissClipSegments, "ask"), name: "quiz-ask" },
  { ...shotNamed(quizMissClipSegments, "question"), name: "quiz-question" },
  { ...shotNamed(quizMissClipSegments, "wrong"), name: "quiz-wrong" },
  { ...shotNamed(quizMissClipSegments, "update"), name: "quiz-update" },
  { ...shotNamed(quizMissClipSegments, "open"), name: "quiz-open" },
  {
    // study-guide.events.txt: the page scrolls to its key terms from 70.6, and the mouse glides to the (1:05) link of a
    // key term and clicks at about 79.2.
    kind: "shot",
    name: "guide-key-terms",
    recordingFile: "study-guide.mov",
    cursorTrackFile: "study-guide.cursor.json",
    sourceStartSeconds: 70.9,
    durationSeconds: 8.5,
    cameraMoves: [{ atSeconds: 0, scale: 1.6, focus: keyTermLink, durationFrames: 1 }],
    captions: [{ fromSeconds: 0.3, toSeconds: 8.2, text: "Every point and key term links back to its moment", accentWords: ["its moment"] }],
  },
  { ...shotNamed(studyGuideClipSegments, "jump"), name: "guide-jump" },
  // The music fades out under this card.
  { kind: "endCard", name: "end-card", recordingFile: "study-guide.mov", sourceStartSeconds: 82, durationSeconds: 4.0 },
];
