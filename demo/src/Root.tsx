import { type CalculateMetadataFunction, Composition, staticFile } from "remotion";
import type { CursorTrack } from "./camera.ts";
import { Demo, demoDurationInFrames, type DemoProps } from "./Demo.tsx";
import { frameRate, videoHeight, videoWidth } from "./motion.ts";
import { quizClipSegments, segments } from "./timeline.ts";

/** The tracker writes these next to the recordings, and each composition reads its own once before rendering. */
const loadCursorTracks: CalculateMetadataFunction<DemoProps> = async ({ props }) => {
  const cursorTracks: Record<string, CursorTrack> = {};
  const trackFiles = new Set(props.segments.flatMap((segment) => (segment.kind === "shot" && segment.cursorTrackFile ? [segment.cursorTrackFile] : [])));
  for (const trackFile of trackFiles) {
    const response = await fetch(staticFile(trackFile));
    if (response.ok) cursorTracks[trackFile] = (await response.json()) as CursorTrack;
  }
  return { props: { ...props, cursorTracks } };
};

export function Root() {
  return (
    <>
      <Composition
        id="ClickyDemo"
        component={Demo}
        width={videoWidth}
        height={videoHeight}
        fps={frameRate}
        durationInFrames={demoDurationInFrames(segments)}
        defaultProps={{ segments, cursorTracks: {} } satisfies DemoProps}
        calculateMetadata={loadCursorTracks}
      />
      {/* The follow-up clip: a quiz pass and a moving picture. */}
      <Composition
        id="ClickyQuizClip"
        component={Demo}
        width={videoWidth}
        height={videoHeight}
        fps={frameRate}
        durationInFrames={demoDurationInFrames(quizClipSegments)}
        defaultProps={{ segments: quizClipSegments, cursorTracks: {} } satisfies DemoProps}
        calculateMetadata={loadCursorTracks}
      />
    </>
  );
}
