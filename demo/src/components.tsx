import type { ReactNode } from "react";
import { AbsoluteFill, Freeze, OffthreadVideo, staticFile, useCurrentFrame } from "remotion";
import { cameraAt, cameraTransform, type CameraMove, type CursorTrack } from "./camera.ts";
import type { DemoTheme } from "./theme.ts";
import {
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
  /** Replaces the theme's accent color for this caption, such as green for a finished agent's check mark. */
  accentColor?: string;
};

const captionExitFrames = 8;

function MicGlyph({ color }: { color: string }) {
  return (
    <svg width="32" height="32" viewBox="0 0 24 24" fill="none" style={{ flexShrink: 0 }}>
      <rect x="8.5" y="3" width="7" height="12" rx="3.5" fill={color} />
      <path d="M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3" stroke={color} strokeWidth="2" strokeLinecap="round" />
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

const highlighterSweepFrames = 12;

/** A marker stroke behind the words, drawn left to right once, starting after the caption has risen in. */
function HighlightedWords({ text, color, sweepProgress }: { text: string; color: string; sweepProgress: number }) {
  return (
    <span
      style={{
        backgroundImage: `linear-gradient(${color}, ${color})`,
        backgroundRepeat: "no-repeat",
        backgroundPosition: "0 78%",
        backgroundSize: `${sweepProgress * 100}% 46%`,
        padding: "0 0.08em",
        margin: "0 -0.08em",
      }}
    >
      {text}
    </span>
  );
}

function AccentedText({
  text,
  accentWords = [],
  accent,
  highlighterProgress,
}: {
  text: string;
  accentWords?: string[];
  accent: DemoTheme["accent"];
  highlighterProgress: number;
}) {
  if (accentWords.length === 0) return <>{text}</>;
  const accentPattern = new RegExp(`(${accentWords.map((word) => word.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|")})`, "g");
  return (
    <>
      {text.split(accentPattern).map((piece, pieceIndex) =>
        !accentWords.includes(piece) ? (
          <span key={pieceIndex}>{piece}</span>
        ) : accent.style === "highlighter" ? (
          <HighlightedWords key={pieceIndex} text={piece} color={accent.color} sweepProgress={highlighterProgress} />
        ) : (
          <span key={pieceIndex} style={{ color: accent.color }}>{piece}</span>
        ),
      )}
    </>
  );
}

/** Whole phrases fade and rise in over 10 frames and fade out over 8, with no bounce. */
export function CaptionTrack({ captions, theme }: { captions: Caption[]; theme: DemoTheme }) {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ justifyContent: "flex-end", alignItems: "center", pointerEvents: "none" }}>
      {captions.map((caption, captionIndex) => {
        const fromFrame = Math.round(caption.fromSeconds * frameRate);
        const toFrame = Math.round(caption.toSeconds * frameRate);
        if (frame < fromFrame || frame > toFrame) return null;
        const enter = softProgress(frame, fromFrame, typographyEnterFrames);
        const exit = softProgress(frame, toFrame - captionExitFrames, captionExitFrames);
        const highlighterProgress = softProgress(frame, fromFrame + typographyEnterFrames, highlighterSweepFrames);
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
              borderRadius: theme.captionCornerRadius,
              background: theme.captionFill,
              border: `1px solid ${theme.captionBorder}`,
              boxShadow: "0 12px 36px rgba(0, 0, 0, 0.35)",
              color: theme.captionText,
              fontFamily: theme.captionFont,
              fontWeight: caption.voice ? 600 : 500,
              // Large enough to read when the 16:9 video plays across a phone held upright.
              fontSize: 50,
              lineHeight: 1.25,
              letterSpacing: -0.2,
            }}
          >
            {caption.voice === "learner" ? <MicGlyph color={theme.micColor} /> : null}
            {caption.voice === "clicky" ? <ClickyTriangleGlyph /> : null}
            <span>
              {caption.voice ? "“" : null}
              <AccentedText text={caption.text} accentWords={caption.accentWords} accent={caption.accentColor ? { ...theme.accent, color: caption.accentColor } : theme.accent} highlighterProgress={highlighterProgress} />
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

/**
 * The sound crossfades with the picture: it rises over a shot's first dissolve and falls over its last, so two shots
 * that overlap never play their sound at full volume together. When the next shot starts where this one's last
 * dissolve begins, the two halves are the same moments and add back up to the full sound. A shot held past its
 * sound fades out the same way, ending at soundEndsAtSeconds.
 */
function shotVolume(shotFrame: number, shotDurationInFrames: number, soundEndFrame: number): number {
  return Math.max(0, Math.min(1, shotFrame / dissolveFrames, (Math.min(shotDurationInFrames, soundEndFrame) - shotFrame) / dissolveFrames));
}

/** A stretch of a recording, with its camera moves, Ken Burns drift, and captions. */
export function Shot({
  recordingFile,
  sourceStartSeconds,
  durationSeconds,
  cameraMoves,
  cursorTrack,
  captions,
  theme,
  muted,
  soundEndsAtSeconds,
  sourceCredit,
  holdsStill,
}: {
  recordingFile: string;
  sourceStartSeconds: number;
  durationSeconds: number;
  cameraMoves: CameraMove[];
  cursorTrack?: CursorTrack;
  captions: Caption[];
  theme: DemoTheme;
  muted: boolean;
  soundEndsAtSeconds?: number;
  sourceCredit?: string;
  holdsStill?: boolean;
}) {
  const frame = useCurrentFrame();
  const recording = (
    <OffthreadVideo
      src={staticFile(recordingFile)}
      trimBefore={Math.round(sourceStartSeconds * frameRate)}
      muted={muted || holdsStill === true}
      volume={(shotFrame) =>
        shotVolume(shotFrame, Math.round(durationSeconds * frameRate), Math.round((soundEndsAtSeconds ?? durationSeconds) * frameRate))
      }
    />
  );
  const camera = cameraAt(cameraMoves, frame / frameRate, durationSeconds, sourceStartSeconds, cursorTrack);
  return (
    <AbsoluteFill style={{ background: colors.background, overflow: "hidden" }}>
      <AbsoluteFill
        style={{
          transformOrigin: "0 0",
          transform: cameraTransform(camera.scale, camera.focus, videoWidth, videoHeight),
        }}
      >
        {holdsStill ? <Freeze frame={0}>{recording}</Freeze> : recording}
      </AbsoluteFill>
      <CaptionTrack captions={captions} theme={theme} />
      {sourceCredit ? <SourceCredit text={sourceCredit} theme={theme} /> : null}
    </AbsoluteFill>
  );
}

/** A small line in the top left corner naming the footage, so the video's makers get credit where it first shows. */
function SourceCredit({ text, theme }: { text: string; theme: DemoTheme }) {
  return (
    <div
      style={{
        position: "absolute",
        top: 36,
        left: 40,
        padding: "8px 16px",
        borderRadius: theme.captionCornerRadius,
        background: "rgba(10, 11, 15, 0.55)",
        color: "rgba(255, 255, 255, 0.9)",
        fontFamily: theme.captionFont,
        fontSize: 26,
        fontWeight: 500,
      }}
    >
      {text}
    </div>
  );
}

/**
 * The closing card: the last scene, blurred and darkened and muted, under the name and the handle. The card fades in
 * with the shot's dissolve, and each line rises in after it with the captions' soft ease.
 */
export function EndCard({ recordingFile, sourceStartSeconds, theme }: { recordingFile: string; sourceStartSeconds: number; theme: DemoTheme }) {
  const frame = useCurrentFrame();
  const nameEnter = softProgress(frame, 8, typographyEnterFrames);
  const taglineEnter = softProgress(frame, 12, typographyEnterFrames);
  const handleEnter = softProgress(frame, 16, typographyEnterFrames);
  const { endCard } = theme;
  return (
    <AbsoluteFill style={{ background: colors.background, overflow: "hidden" }}>
      <AbsoluteFill style={{ transform: "scale(1.12)", filter: "blur(28px)" }}>
        <OffthreadVideo src={staticFile(recordingFile)} trimBefore={Math.round(sourceStartSeconds * frameRate)} muted />
      </AbsoluteFill>
      <AbsoluteFill style={{ background: endCard.scrim }} />
      <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", gap: 22, fontFamily: theme.captionFont, color: endCard.titleColor }}>
        <div style={{ fontSize: 96, fontWeight: 700, letterSpacing: -1.5, opacity: nameEnter, transform: `translateY(${(1 - nameEnter) * typographyRisePixels}px)` }}>
          {endCard.title}
        </div>
        {endCard.tagline ? (
          <div style={{ fontSize: 44, fontWeight: 500, opacity: taglineEnter * 0.85, transform: `translateY(${(1 - taglineEnter) * typographyRisePixels}px)` }}>
            {endCard.tagline}
          </div>
        ) : null}
        <div style={{ fontSize: 48, fontWeight: 600, color: endCard.handleColor, opacity: handleEnter, transform: `translateY(${(1 - handleEnter) * typographyRisePixels}px)` }}>
          {endCard.handle}
        </div>
        {endCard.credit ? (
          <div style={{ fontSize: 28, fontWeight: 500, opacity: handleEnter * 0.6, transform: `translateY(${(1 - handleEnter) * typographyRisePixels}px)` }}>
            {endCard.credit}
          </div>
        ) : null}
      </AbsoluteFill>
    </AbsoluteFill>
  );
}
