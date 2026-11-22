import { AbsoluteFill, Sequence } from "remotion";
import type { CursorTrack } from "./camera.ts";
import { BlurDissolve, EndCard, Shot, TitleCard } from "./components.tsx";
import { colors, dissolveFrames, seconds } from "./motion.ts";
import type { DemoTheme } from "./theme.ts";
import type { Segment } from "./timeline.ts";

export type DemoProps = { segments: Segment[]; cursorTracks: Record<string, CursorTrack>; theme: DemoTheme };

/** Each segment starts one dissolve before the previous one ends, so they overlap in a blur-dissolve. */
export function segmentStartFrames(segments: Segment[]): number[] {
  const startFrames: number[] = [];
  let nextStartFrame = 0;
  for (const segment of segments) {
    startFrames.push(nextStartFrame);
    nextStartFrame += seconds(segment.durationSeconds) - dissolveFrames;
  }
  return startFrames;
}

export function demoDurationInFrames(segments: Segment[]): number {
  const startFrames = segmentStartFrames(segments);
  const lastSegment = segments[segments.length - 1];
  return (startFrames[startFrames.length - 1] ?? 0) + (lastSegment ? seconds(lastSegment.durationSeconds) : 0);
}

export function Demo({ segments, cursorTracks, theme }: DemoProps) {
  const startFrames = segmentStartFrames(segments);
  return (
    <AbsoluteFill style={{ background: colors.background }}>
      {segments.map((segment, segmentIndex) => {
        const durationInFrames = seconds(segment.durationSeconds);
        return (
          <Sequence key={segment.name} from={startFrames[segmentIndex] ?? 0} durationInFrames={durationInFrames} name={segment.name}>
            <BlurDissolve durationInFrames={durationInFrames} fadesOut={segmentIndex === segments.length - 1} fadesIn={!(segmentIndex === 0 && segment.kind === "shot" && segment.opensOnItsFirstFrame)}>
              {segment.kind === "shot" ? (
                <Shot
                  recordingFile={segment.recordingFile}
                  sourceStartSeconds={segment.sourceStartSeconds}
                  durationSeconds={segment.durationSeconds}
                  cameraMoves={segment.cameraMoves}
                  cursorTrack={segment.cursorTrackFile ? cursorTracks[segment.cursorTrackFile] : undefined}
                  captions={segment.captions}
                  theme={theme}
                  muted={segment.muted ?? false}
                  soundEndsAtSeconds={segment.soundEndsAtSeconds}
                  sourceCredit={segment.sourceCredit}
                  holdsStill={segment.holdsStill}
                  pageCrop={segment.pageCrop}
                  captionPosition={segment.captionPosition}
                />
              ) : segment.kind === "titleCard" ? (
                <TitleCard recordingFile={segment.recordingFile} sourceStartSeconds={segment.sourceStartSeconds} text={segment.text} accentWords={segment.accentWords} theme={theme} />
              ) : (
                <EndCard recordingFile={segment.recordingFile} sourceStartSeconds={segment.sourceStartSeconds} theme={theme} />
              )}
            </BlurDissolve>
          </Sequence>
        );
      })}
    </AbsoluteFill>
  );
}
