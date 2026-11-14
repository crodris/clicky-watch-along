import type { ReactNode } from "react";
import { AbsoluteFill, OffthreadVideo, staticFile, useCurrentFrame } from "remotion";
import { cameraAt, cameraTransform, type CameraMove, type CursorTrack } from "./camera.ts";
import {
  bodyFont,
  colors,
  dissolveFrames,
  easeInOutQuadratic,
  progressBetween,
  frameRate,
  softProgress,
  typographyEnterFrames,
  typographyRisePixels,
  videoHeight,
  videoWidth,
} from "./motion.ts";

/**
 * One phrase at the bottom. A learner's spoken request shows a mic and quotes, a line Clicky speaks shows its blue
 * triangle and quotes, and the rest say what is happening.
 */
export type Caption = {
  fromSeconds: number;
  toSeconds: number;
  text: string;
  voice?: "learner" | "clicky";
  /** Words drawn in the caption accent color. */
  accentWords?: string[];
};

const captionExitFrames = 8;

function MicGlyph() {
  return (
    <svg width="32" height="32" viewBox="0 0 24 24" fill="none" style={{ flexShrink: 0 }}>
      <rect x="8.5" y="3" width="7" height="12" rx="3.5" fill={colors.captionAccent} />
      <path d="M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3" stroke={colors.captionAccent} strokeWidth="2" strokeLinecap="round" />
    </svg>
  );
}

function ClickyTriangleGlyph() {
  return (
    <svg width="28" height="28" viewBox="0 0 24 24" style={{ flexShrink: 0 }}>
      <path d="M5 3 L20 11 L12.5 13 L9.5 20 Z" fill={colors.clickyBlue} />
    </svg>
  );
}

function AccentedText({ text, accentWords = [] }: { text: string; accentWords?: string[] }) {
  if (accentWords.length === 0) return <>{text}</>;
  const accentPattern = new RegExp(`(${accentWords.map((word) => word.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|")})`, "g");
  return (
    <>
      {text.split(accentPattern).map((piece, pieceIndex) =>
        accentWords.includes(piece) ? (
          <span key={pieceIndex} style={{ color: colors.captionAccent }}>{piece}</span>
        ) : (
          <span key={pieceIndex}>{piece}</span>
        ),
      )}
    </>
  );
}

/** Whole phrases fade and rise in over 10 frames and fade out over 8, with no bounce. */
export function CaptionTrack({ captions }: { captions: Caption[] }) {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ justifyContent: "flex-end", alignItems: "center", pointerEvents: "none" }}>
      {captions.map((caption, captionIndex) => {
        const fromFrame = Math.round(caption.fromSeconds * frameRate);
        const toFrame = Math.round(caption.toSeconds * frameRate);
        if (frame < fromFrame || frame > toFrame) return null;
        const enter = softProgress(frame, fromFrame, typographyEnterFrames);
        const exit = softProgress(frame, toFrame - captionExitFrames, captionExitFrames);
        return (
          <div
            key={captionIndex}
            style={{
              position: "absolute",
              bottom: 56,
              opacity: enter * (1 - exit),
              transform: `translateY(${(1 - enter) * typographyRisePixels}px)`,
              display: "flex",
              alignItems: "center",
              gap: 16,
              maxWidth: 1640,
              padding: caption.voice ? "20px 40px 20px 30px" : "20px 40px",
              borderRadius: 999,
              background: colors.pillFill,
              border: `1px solid ${colors.pillBorder}`,
              boxShadow: "0 12px 36px rgba(0, 0, 0, 0.35)",
              color: colors.text,
              fontFamily: bodyFont,
              fontWeight: caption.voice ? 600 : 500,
              // Large enough to read when the 16:9 video plays across a phone held upright.
              fontSize: 50,
              lineHeight: 1.25,
              letterSpacing: -0.2,
            }}
          >
            {caption.voice === "learner" ? <MicGlyph /> : null}
            {caption.voice === "clicky" ? <ClickyTriangleGlyph /> : null}
            <span>
              {caption.voice ? "“" : null}
              <AccentedText text={caption.text} accentWords={caption.accentWords} />
              {caption.voice ? "”" : null}
            </span>
          </div>
        );
      })}
    </AbsoluteFill>
  );
}

/**
 * #044 Cross dissolve with the brief's blur: the next shot fades in on top of this one over 15 frames,
 * quadratic ease-in-out, while this one stays fully opaque underneath and only blurs out (up to 12 px).
 * The first shot fades in the same way from the dark background, and the last one fades out to it.
 */
export function BlurDissolve({ durationInFrames, children, fadesOut }: { durationInFrames: number; children: ReactNode; fadesOut: boolean }) {
  const frame = useCurrentFrame();
  const inProgress = easeInOutQuadratic(progressBetween(frame, 0, dissolveFrames));
  const outProgress = easeInOutQuadratic(progressBetween(frame, durationInFrames - dissolveFrames, durationInFrames));
  const blurPixels = 12 * Math.max(1 - inProgress, outProgress);
  const opacity = fadesOut ? inProgress * (1 - outProgress) : inProgress;
  return (
    <AbsoluteFill style={{ opacity, filter: blurPixels > 0.05 ? `blur(${blurPixels}px)` : undefined }}>
      {children}
    </AbsoluteFill>
  );
}

/** A stretch of a recording, with its camera moves, Ken Burns drift, and captions. */
export function Shot({
  recordingFile,
  sourceStartSeconds,
  durationSeconds,
  cameraMoves,
  cursorTrack,
  captions,
}: {
  recordingFile: string;
  sourceStartSeconds: number;
  durationSeconds: number;
  cameraMoves: CameraMove[];
  cursorTrack?: CursorTrack;
  captions: Caption[];
}) {
  const frame = useCurrentFrame();
  const camera = cameraAt(cameraMoves, frame / frameRate, durationSeconds, sourceStartSeconds, cursorTrack);
  return (
    <AbsoluteFill style={{ background: colors.background, overflow: "hidden" }}>
      <AbsoluteFill
        style={{
          transformOrigin: "0 0",
          transform: cameraTransform(camera.scale, camera.focus, videoWidth, videoHeight),
        }}
      >
        <OffthreadVideo src={staticFile(recordingFile)} trimBefore={Math.round(sourceStartSeconds * frameRate)} />
      </AbsoluteFill>
      <CaptionTrack captions={captions} />
    </AbsoluteFill>
  );
}

/**
 * The closing card: the last scene, blurred and darkened and muted, under the name and the handle. The card fades in
 * with the shot's dissolve, and each line rises in after it with the captions' soft ease.
 */
export function EndCard({ recordingFile, sourceStartSeconds }: { recordingFile: string; sourceStartSeconds: number }) {
  const frame = useCurrentFrame();
  const nameEnter = softProgress(frame, 8, typographyEnterFrames);
  const handleEnter = softProgress(frame, 16, typographyEnterFrames);
  return (
    <AbsoluteFill style={{ background: colors.background, overflow: "hidden" }}>
      <AbsoluteFill style={{ transform: "scale(1.12)", filter: "blur(28px)" }}>
        <OffthreadVideo src={staticFile(recordingFile)} trimBefore={Math.round(sourceStartSeconds * frameRate)} muted />
      </AbsoluteFill>
      <AbsoluteFill style={{ background: "rgba(10, 11, 15, 0.62)" }} />
      <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", gap: 22, fontFamily: bodyFont, color: colors.text }}>
        <div style={{ fontSize: 96, fontWeight: 700, letterSpacing: -1.5, opacity: nameEnter, transform: `translateY(${(1 - nameEnter) * typographyRisePixels}px)` }}>
          Clicky watch-along
        </div>
        <div style={{ fontSize: 48, fontWeight: 600, color: colors.captionAccent, opacity: handleEnter, transform: `translateY(${(1 - handleEnter) * typographyRisePixels}px)` }}>
          @HayloCR
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
}
