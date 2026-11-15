import type { CameraMove } from "./camera.ts";
import type { Caption } from "./components.tsx";
import { subAgentTaskTeal } from "./theme.ts";

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
  /** Where the sound fades out, in seconds into the shot, so a held shot can run on past a line it must not play. */
  soundEndsAtSeconds?: number;
  /** Names the footage in a small corner line, such as "Video: Science ABC", for the shot that first shows it. */
  sourceCredit?: string;
  /** Holds the shot's first frame, muted, so a viewer can read what is on screen before the take moves on. */
  holdsStill?: boolean;
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
const youtubeVideo = { x: 0.57, y: 0.49 };
const youtubeVideoScale = 1.28;
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
      { atSeconds: 0, scale: youtubeVideoScale, focus: youtubeVideo, durationFrames: 1 },
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
      { atSeconds: 0, scale: youtubeVideoScale, focus: youtubeVideo, durationFrames: 1 },
      { atSeconds: 1.7, scale: labelScale, focus: studyGuideChip, durationFrames: bigMoveFrames },
      { atSeconds: 5.8, scale: youtubeVideoScale, focus: youtubeVideo, durationFrames: bigMoveFrames },
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
    cameraMoves: [{ atSeconds: 0, scale: youtubeVideoScale, focus: youtubeVideo, durationFrames: 1 }],
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
      { atSeconds: 0, scale: youtubeVideoScale, focus: youtubeVideo, durationFrames: 1 },
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
    cameraMoves: [{ atSeconds: 0, scale: youtubeVideoScale, focus: youtubeVideo, durationFrames: 1 }],
    captions: [{ fromSeconds: 0.3, toSeconds: 4.4, text: "Click one, and the video jumps right there", accentWords: ["jumps right there"] }],
  },
  // The music fades out under this card.
  { kind: "endCard", name: "end-card", recordingFile: "study-guide.mov", sourceStartSeconds: 82, durationSeconds: 4.0 },
];

// The quiz miss clip, posted after the parallel sub-agents clip, which already explains the sub-agent mechanics. So
// this one is about what only it shows: Clicky quizzes you, you miss one, and your study guide fixes itself. It plays
// over Science ABC's "How Submarines Work", a 2D illustration, which lifts out of the video as a puffed-up drawing. The
// take writes the guide first, off camera, and answers the first question right, which the edit leaves out, so the clip
// starts at the quiz request and ends on the guide's key term links.
// The diving planes "?" sits low on the right of the lifted submarine, with the question in the cursor's bubble below
// it, and the update helper's chip opens just left of it. At 1.6 times most of the submarine stays in view.
const divingPlanesQuestion = { x: 0.7, y: 0.7 };
const divingPlanesScale = 1.6;
// The ballast tanks "?" sits left of the cross-section, below its other labels, and 1.5 times keeps the whole
// cross-section in view. The focus sits low enough that the question's bubble stays above the captions.
const ballastTanksQuestion = { x: 0.46, y: 0.64 };
const ballastTanksScale = 1.5;
// "Review these first" and its first item sit just under the page's summary.
const reviewTheseFirst = { x: 0.62, y: 0.6 };
// The buoyancy key term's (1:00) link, once the page has scrolled it to the middle.
const quizKeyTermLink = { x: 0.62, y: 0.56 };
const scienceABCCredit = "Video: Science ABC, How Submarines Work";

export const quizMissClipSegments: Segment[] = [
  {
    // quiz-miss.events.txt: the guide was written at 27.38, and its finished helper is still beside the cursor at the
    // start. "Watch this video with me and quiz me" at 31.82, and Clicky says "Sure, let me read through this video."
    // from 32.68 to 34.56.
    kind: "shot",
    name: "ask",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    // It starts at 27.6, while the "Study guide ready" chip from that write is still up under the cursor.
    sourceStartSeconds: 27.6,
    durationSeconds: 7.4,
    cameraMoves: [{ atSeconds: 0, scale: youtubeVideoScale, focus: youtubeVideo, durationFrames: 1 }],
    sourceCredit: scienceABCCredit,
    captions: [
      { fromSeconds: 0.2, toSeconds: 2.3, text: "My Clicky fork quizzes you while you watch", accentWords: ["quizzes you"] },
      { fromSeconds: 2.4, toSeconds: 4.1, text: "It already wrote this video's study guide", accentWords: ["study guide"] },
      { fromSeconds: 4.2, toSeconds: 7.2, text: "Watch this video with me and quiz me", voice: "learner" },
    ],
  },
  {
    // The take answers the first question, about buoyancy, off camera. The video pauses at 139.84 for the diving planes
    // question, and the submarine lifts out of the frame from 139.95.
    kind: "shot",
    name: "lift",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 139.6,
    durationSeconds: 3.2,
    cameraMoves: [{ atSeconds: 0, scale: youtubeVideoScale, focus: youtubeVideo, durationFrames: 1 }],
    captions: [{ fromSeconds: 0.2, toSeconds: 3.0, text: "It pauses at the right moment and lifts the drawing out in 3D", accentWords: ["3D"] }],
  },
  {
    // After the tour, Clicky asks "What are a submarine's fin-like parts that help it control pitch to go up or down?"
    // from 145.15 to 149.95, while the blue cursor sits at the "?" and its bubble types it.
    kind: "shot",
    name: "question",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 144.9,
    durationSeconds: 5.4,
    cameraMoves: [
      { atSeconds: 0, scale: youtubeVideoScale, focus: youtubeVideo, durationFrames: 1 },
      { atSeconds: 0.2, scale: divingPlanesScale, focus: divingPlanesQuestion, durationFrames: bigMoveFrames },
    ],
    captions: [{ fromSeconds: 1.0, toSeconds: 5.2, text: "The question stays in the cursor's bubble", accentWords: ["cursor's bubble"] }],
  },
  {
    // "Is it the propeller" at 150.35. The "?" shakes once, and Clicky says "Not quite." from 152.90 to 153.79. The sound
    // is out before its explanation starts at 154.10.
    kind: "shot",
    name: "wrong",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 150.1,
    durationSeconds: 4.0,
    soundEndsAtSeconds: 3.95,
    cameraMoves: [{ atSeconds: 0, scale: divingPlanesScale, focus: divingPlanesQuestion, durationFrames: 1 }],
    captions: [{ fromSeconds: 0.3, toSeconds: 2.6, text: "Is it the propeller?", voice: "learner" }],
  },
  {
    // "Is it the diving planes" at 164.47. The label turns green, the miss spawns the update helper at 167.00, which
    // writes the guide at 168.05 and shows the "Study guide updated" chip. Clicky says "Yes, you named the diving planes."
    // from 166.34 to 169.40, and the sound is out before its follow-up question at 169.70, while the picture holds on
    // the chip.
    kind: "shot",
    name: "update",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 164.4,
    durationSeconds: 6.0,
    soundEndsAtSeconds: 5.25,
    cameraMoves: [{ atSeconds: 0, scale: divingPlanesScale, focus: divingPlanesQuestion, durationFrames: 1 }],
    captions: [
      { fromSeconds: 0.1, toSeconds: 1.9, text: "Is it the diving planes?", voice: "learner" },
      { fromSeconds: 2.2, toSeconds: 5.8, text: "A sub-agent writes the miss into your study guide", accentWords: ["your study guide"] },
    ],
  },
  {
    // The bubble finishes typing the third question at about 249.6, and the answer comes at 249.94, so this holds the
    // full question still for a moment first.
    kind: "shot",
    name: "next-question",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 249.8,
    durationSeconds: 2.2,
    holdsStill: true,
    cameraMoves: [{ atSeconds: 0, scale: ballastTanksScale, focus: ballastTanksQuestion, durationFrames: 1 }],
    captions: [{ fromSeconds: 0.4, toSeconds: 2.0, text: "Next question: which tanks let it dive?", accentWords: ["which tanks"] }],
  },
  {
    // The third question, about ballast tanks, with the cross-section lifted out and the question in the cursor's
    // bubble. "Is it the ballast tanks" at 249.94, the label turns green with its ring, and Clicky says "Yes, ballast
    // tanks is right." from 251.90 to 254.07. A first-try answer is not added to the guide's review list.
    kind: "shot",
    name: "right",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 249.7,
    durationSeconds: 4.6,
    soundEndsAtSeconds: 4.42,
    cameraMoves: [{ atSeconds: 0, scale: ballastTanksScale, focus: ballastTanksQuestion, durationFrames: 1 }],
    captions: [
      { fromSeconds: 0.2, toSeconds: 1.9, text: "Is it the ballast tanks?", voice: "learner" },
      { fromSeconds: 2.0, toSeconds: 4.4, text: "Right on the first try stays off the review list", accentWords: ["first try"] },
    ],
  },
  {
    // "Open my study guide" at 267.77, the page is in front by 269.8, and Clicky says "Opening your study guide." from
    // 270.22 to 271.50.
    kind: "shot",
    name: "open",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 267.5,
    durationSeconds: 6.4,
    cameraMoves: [
      { atSeconds: 0, scale: youtubeVideoScale, focus: youtubeVideo, durationFrames: 1 },
      { atSeconds: 2.6, scale: 1.7, focus: reviewTheseFirst, durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.2, toSeconds: 2.2, text: "Open my study guide", voice: "learner" },
      { fromSeconds: 3.1, toSeconds: 6.2, text: "The miss is already at the top", accentWords: ["already at the top"] },
    ],
  },
  {
    // The driver scrolls the page to its key terms, and the mouse glides to the buoyancy term's (1:00) link and clicks
    // it at about 281.5.
    kind: "shot",
    name: "key-terms",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 277.2,
    durationSeconds: 4.8,
    cameraMoves: [{ atSeconds: 0, scale: 1.6, focus: quizKeyTermLink, durationFrames: 1 }],
    captions: [{ fromSeconds: 0.2, toSeconds: 4.6, text: "Every key term links back to its moment", accentWords: ["its moment"] }],
  },
  {
    // The link opens the video at 1:00 in a new tab, where it plays from about 285.8.
    kind: "shot",
    name: "jump",
    recordingFile: "quiz-miss.mov",
    cursorTrackFile: "quiz-miss.cursor.json",
    sourceStartSeconds: 285.8,
    durationSeconds: 3.9,
    cameraMoves: [{ atSeconds: 0, scale: youtubeVideoScale, focus: youtubeVideo, durationFrames: 1 }],
    // The end card dissolves in over the last 0.5 seconds, so the caption ends before that.
    captions: [{ fromSeconds: 0.2, toSeconds: 3.3, text: "Click one, and the video jumps right there", accentWords: ["jumps right there"] }],
  },
  // The music fades out under this card.
  { kind: "endCard", name: "end-card", recordingFile: "quiz-miss.mov", sourceStartSeconds: 288, durationSeconds: 4.0 },
];

// The parallel agents clip, posted first because the catch is the news, so it teaches the sub-agent mechanics itself: a
// general task agent and a 3D model built in the background, at once, while SpaceX's own clip of Starship Flight 15's
// tower catch plays on x.com. The clip plays muted, so only Clicky and the music are heard. The driver hides X's side
// columns and replies, so the player sits alone in the middle of the page, and 2.2 times fills most of the frame with it.
// The hiding runs at 3.1 seconds, so the clip starts after it.
const starshipVideo = { x: 0.536, y: 0.401 };
const starshipVideoScale = 2.2;
// The agent list opens just below and right of the blue triangle, which rests at about (0.67, 0.69).
const agentList = { x: 0.745, y: 0.76 };
const agentChip = { x: 0.72, y: 0.74 };
// The model rises to fill the screen, so the camera pulls back to the whole frame for it.
const wholeFrame = { x: 0.5, y: 0.5 };
// The Notion page's body, right of Chrome's tab sidebar and Notion's own sidebar, which lists private page titles and
// the account's name, so the camera keeps both out of the frame.
const notionPageBody = { x: 0.67, y: 0.5 };
const notionPageScale = 1.6;

export const parallelAgentsClipSegments: Segment[] = [
  {
    // agents.events.txt: the request at 5.99, while the ship descends on its landing burn, and start_background_task
    // spawns the teal task agent at 7.64, whose line says "Getting started" and then the steps it reports.
    kind: "shot",
    name: "ask-task",
    recordingFile: "agents.mov",
    cursorTrackFile: "agents.cursor.json",
    // The hiding runs at about 3.1 and the clip jumps to 50 seconds between 3.5 and 3.6, so the shot starts at 3.7.
    sourceStartSeconds: 3.7,
    sourceCredit: "Video: SpaceX, Mechazilla catches Starship!",
    durationSeconds: 8.6,
    cameraMoves: [
      { atSeconds: 0, scale: starshipVideoScale, focus: starshipVideo, durationFrames: 1 },
      { atSeconds: 5.1, scale: helperScale, focus: "cursor", durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.2, toSeconds: 2.8, text: "My Clicky fork, an AI on your cursor, watching SpaceX's catch with you", accentWords: ["an AI on your cursor"] },
      { fromSeconds: 2.9, toSeconds: 5.8, text: "Find out how this catch compares to the first booster catch, and make me a Notion page about it", voice: "learner" },
      { fromSeconds: 5.9, toSeconds: 8.4, text: "That spawns a general sub-agent that plans its own steps", accentWords: ["general sub-agent"], accentColor: subAgentTaskTeal },
    ],
  },
  {
    // The ship flies down to the tower from 13.8, and the arms close around it at about 19 while the task agent searches.
    kind: "shot",
    name: "catch",
    recordingFile: "agents.mov",
    cursorTrackFile: "agents.cursor.json",
    sourceStartSeconds: 13.8,
    durationSeconds: 8.5,
    cameraMoves: [{ atSeconds: 0, scale: starshipVideoScale, focus: starshipVideo, durationFrames: 1 }],
    captions: [
      { fromSeconds: 0.4, toSeconds: 4.0, text: "Sub-agent 1 searches the web in the background", accentWords: ["searches the web"], accentColor: subAgentTaskTeal },
      { fromSeconds: 4.3, toSeconds: 8.2, text: "The main agent stays free, and the catch plays on", accentWords: ["stays free"] },
    ],
  },
  {
    // The request at 26.35, over the wide shot of the ship in the tower's arms, build_model_in_background spawns the
    // violet sub-agent at 27.38, and the agent list is open from about 28.5 to 33.0, saying "2 running".
    kind: "shot",
    name: "ask-model",
    recordingFile: "agents.mov",
    cursorTrackFile: "agents.cursor.json",
    sourceStartSeconds: 26.2,
    durationSeconds: 6.8,
    cameraMoves: [
      { atSeconds: 0, scale: starshipVideoScale, focus: starshipVideo, durationFrames: 1 },
      { atSeconds: 2.5, scale: 2.4, focus: agentList, durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.2, toSeconds: 1.9, text: "Build me a 3D model of this Starship", voice: "learner" },
      { fromSeconds: 2.0, toSeconds: 3.6, text: "Sub-agent 2 builds it, in violet", accentWords: ["Sub-agent 2"] },
      { fromSeconds: 3.8, toSeconds: 6.6, text: "Shift + option lists them: 2 running at once", accentWords: ["2 running"] },
    ],
  },
  {
    // The mouse glides out and back from 33.9 to 37.6, and both wingmen trail the blue triangle with their step lines.
    kind: "shot",
    name: "formation",
    recordingFile: "agents.mov",
    cursorTrackFile: "agents.cursor.json",
    sourceStartSeconds: 33.7,
    durationSeconds: 4.1,
    cameraMoves: [{ atSeconds: 0, scale: 2.2, focus: "cursor", durationFrames: 1 }],
    captions: [
      { fromSeconds: 0.3, toSeconds: 4.0, text: "One searches the web while the other builds the model", accentWords: ["searches the web"], accentColor: subAgentTaskTeal },
    ],
  },
  {
    // The task agent finishes at 41.79 while the clip still plays: its wingman fills, gets its check mark, and the chip
    // says "Task done · say what did you find", since the answer waits to be asked for.
    kind: "shot",
    name: "task-done",
    recordingFile: "agents.mov",
    cursorTrackFile: "agents.cursor.json",
    sourceStartSeconds: 41.3,
    durationSeconds: 4.8,
    cameraMoves: [
      { atSeconds: 0, scale: starshipVideoScale, focus: starshipVideo, durationFrames: 1 },
      { atSeconds: 0.5, scale: labelScale, focus: agentChip, durationFrames: bigMoveFrames },
    ],
    captions: [
      // After the chip shows at about 0.6, so the caption never names a result the screen does not show yet.
      { fromSeconds: 1.2, toSeconds: 4.6, text: "Sub-agent 1 done: web research, written to Notion", accentWords: ["done"], accentColor: finishedCheckGreen },
    ],
  },
  {
    // The model is built at 46.43 and the chip says "3D model ready". The driver stopped the clip on its last frame at
    // about 45.6, and nothing else is on screen, so the model rises out of that frame from 47.43.
    kind: "shot",
    name: "rise",
    recordingFile: "agents.mov",
    cursorTrackFile: "agents.cursor.json",
    sourceStartSeconds: 46.0,
    durationSeconds: 7.8,
    cameraMoves: [
      { atSeconds: 0, scale: labelScale, focus: agentChip, durationFrames: 1 },
      { atSeconds: 1.6, scale: 1.0, focus: wholeFrame, durationFrames: bigMoveFrames },
    ],
    captions: [
      { fromSeconds: 0.5, toSeconds: 1.8, text: "Sub-agent 2 done", accentWords: ["done"], accentColor: finishedCheckGreen },
      { fromSeconds: 2.0, toSeconds: 4.9, text: "The screen is free, so the model rises out of the video", accentWords: ["rises out of the video"] },
      { fromSeconds: 5.1, toSeconds: 7.6, text: "GPT-6.1 Sol built it in 19 seconds", accentWords: ["19 seconds"] },
    ],
  },
  {
    // Clicky says what the model shows from 54.71 to 64.71, in one sentence: "Inside the Starship model, you're passing
    // the pointed nose and payload section, then moving down the stainless steel body toward the engine bay with its
    // cluster of Raptor engines." It has no sentence break to cut on, so the shot keeps it whole and drops the silence on
    // each side, ending late enough that "engines" is heard before the dissolve. For viewers with the sound off, the first
    // caption names the labels on screen and the second follows the narration.
    kind: "shot",
    name: "narration",
    recordingFile: "agents.mov",
    cursorTrackFile: "agents.cursor.json",
    sourceStartSeconds: 54.3,
    durationSeconds: 10.9,
    cameraMoves: [{ atSeconds: 0, scale: 1.0, focus: wholeFrame, durationFrames: 1 }],
    captions: [
      { fromSeconds: 0.6, toSeconds: 4.8, text: "It labels the tower, catch arms, and engines", accentWords: ["labels"] },
      { fromSeconds: 5.1, toSeconds: 10.2, text: "Then tours the ship from the nose down to its Raptor engines", accentWords: ["Raptor engines"] },
    ],
  },
  {
    // "Put it back" at 69.21, and the model flattens back into the clip's last frame by about 70.0.
    kind: "shot",
    name: "put-back",
    recordingFile: "agents.mov",
    cursorTrackFile: "agents.cursor.json",
    sourceStartSeconds: 68.9,
    durationSeconds: 3.4,
    cameraMoves: [
      { atSeconds: 0, scale: 1.0, focus: wholeFrame, durationFrames: 1 },
      { atSeconds: 1.6, scale: starshipVideoScale, focus: starshipVideo, durationFrames: bigMoveFrames },
    ],
    captions: [{ fromSeconds: 0.2, toSeconds: 2.1, text: "Put it back", voice: "learner" }],
  },
  {
    // "What did you find" at 72.80, the page comes forward at about 73, and Clicky speaks the task agent's answer from
    // 74.41 to 92.97 while the page scrolls to its sources by about 83.
    kind: "shot",
    name: "answer",
    recordingFile: "agents.mov",
    cursorTrackFile: "agents.cursor.json",
    sourceStartSeconds: 72.6,
    durationSeconds: 20.8,
    cameraMoves: [{ atSeconds: 0, scale: notionPageScale, focus: notionPageBody, durationFrames: 1 }],
    captions: [
      { fromSeconds: 0.2, toSeconds: 1.9, text: "What did you find?", voice: "learner" },
      { fromSeconds: 2.4, toSeconds: 6.0, text: "The answer waits until you ask, so it never talks over the video", accentWords: ["until you ask"], accentColor: subAgentTaskTeal },
      { fromSeconds: 11.0, toSeconds: 14.6, text: "And the page cites its sources", accentWords: ["cites its sources"], accentColor: subAgentTaskTeal },
    ],
  },
  // The music fades out under this card.
  { kind: "endCard", name: "end-card", recordingFile: "agents.mov", sourceStartSeconds: 94, durationSeconds: 4.0 },
];
