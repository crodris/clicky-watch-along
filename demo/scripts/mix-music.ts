// Mixes a music bed under the rendered demo and normalizes the result for posting.
// The voice gets a high-pass at 80 Hz, a small presence lift at 3 kHz, and light compression so it cuts through.
// The music fades in over 1 second and out over the last 3, under the end card. It sits 9 dB below the narration in
// the pauses, and a sidechain compressor keyed on the voice pulls it down about 11 dB more while Clicky speaks, so it
// lands about 20 dB under the voice. A clip that wants Clicky quieter passes a negative voice gain: the voice drops
// against the music, and the quieter voice also ducks the music less. The mix is normalized in two passes to -14 LUFS integrated, with true peaks kept
// under -1 dBTP.
// Usage: node scripts/mix-music.ts <voice.mp4> <music> <out.mp4> [music-start-seconds] [voice-gain-db]
import { spawnSync } from "node:child_process";

const [voicePath, musicPath, outputPath, musicStartArgument, voiceGainArgument] = process.argv.slice(2);
// Where the bed starts in the track, so a sparse intro with near-silent gaps can be skipped.
const musicStartSeconds = Number(musicStartArgument ?? 0);
if (!voicePath || !musicPath || !outputPath) {
  console.error("usage: node scripts/mix-music.ts <voice.mp4> <music> <out.mp4> [music-start-seconds] [voice-gain-db]");
  process.exit(2);
}

const musicBelowVoiceInPausesDb = 9;
// Applied after the music level is set from the voice, so it changes the voice against the music.
const voiceGainDb = Number(voiceGainArgument ?? 0);
if (!Number.isFinite(musicStartSeconds) || musicStartSeconds < 0 || !Number.isFinite(voiceGainDb)) {
  console.error("music-start-seconds must be a number of 0 or more, and voice-gain-db a number");
  process.exit(2);
}
const targetIntegratedLufs = -14;
// loudnorm can overshoot its ceiling by about 0.1 dB, so it aims a little lower to stay under -1 dBTP.
const truePeakCeilingDb = -1.5;

function runFfmpeg(args: string[]): string {
  const result = spawnSync("ffmpeg", ["-hide_banner", "-nostats", ...args], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (result.status !== 0) {
    console.error(result.stderr);
    process.exit(1);
  }
  return result.stderr;
}

const voiceTreatment = "highpass=f=80,equalizer=f=3000:t=o:w=1.2:g=2.5,acompressor=threshold=-24dB:ratio=3:attack=5:release=120:makeup=2";

function integratedLoudness(path: string, filtersBefore = ""): number {
  const report = runFfmpeg(["-i", path, "-vn", "-af", `${filtersBefore ? `${filtersBefore},` : ""}ebur128`, "-f", "null", "-"]);
  const summary = report.slice(report.lastIndexOf("Integrated loudness:"));
  const match = /I:\s+(-?[\d.]+) LUFS/.exec(summary);
  if (!match?.[1]) throw new Error(`no integrated loudness for ${path}`);
  return Number(match[1]);
}

function mediaDurationSeconds(path: string): number {
  const durationResult = spawnSync("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path], { encoding: "utf8" });
  const durationSeconds = Number(durationResult.stdout.trim());
  if (!Number.isFinite(durationSeconds) || durationSeconds <= 0) throw new Error(`no duration for ${path}`);
  return durationSeconds;
}

const durationSeconds = mediaDurationSeconds(voicePath);
// The bed would stop short of the end, before its fade-out, so a track too short for the clip is refused.
const musicSecondsAvailable = mediaDurationSeconds(musicPath) - musicStartSeconds;
if (musicSecondsAvailable < durationSeconds) {
  console.error(`the music has ${musicSecondsAvailable.toFixed(1)} s after its start, and the clip runs ${durationSeconds.toFixed(1)} s`);
  process.exit(2);
}
const fadeOutSeconds = Math.min(3, durationSeconds);

// Integrated loudness gates out silence, so for the voice it measures the narration itself.
const voiceLufs = integratedLoudness(voicePath, voiceTreatment);
const musicLufs = integratedLoudness(musicPath);
const musicGainDb = voiceLufs - musicLufs - musicBelowVoiceInPausesDb;

const mixGraph = [
  `[1:a]atrim=${musicStartSeconds}:${musicStartSeconds + durationSeconds},asetpts=PTS-STARTPTS,aformat=sample_rates=48000:channel_layouts=stereo,`
    + `volume=${musicGainDb.toFixed(2)}dB,afade=t=in:d=1,afade=t=out:st=${(durationSeconds - fadeOutSeconds).toFixed(2)}:d=${fadeOutSeconds.toFixed(2)}[music]`,
  `[0:a]aformat=sample_rates=48000:channel_layouts=stereo,${voiceTreatment},volume=${voiceGainDb}dB,asplit=2[voice][voiceKey]`,
  // About -36 dBFS threshold with a 5:1 ratio takes roughly 11 dB off the music under the treated voice, which
  // measured 20.4 dB between voice and music in half-second windows while Clicky speaks.
  `[music][voiceKey]sidechaincompress=threshold=0.016:ratio=5:attack=30:release=450:knee=3[duckedMusic]`,
  `[voice][duckedMusic]amix=inputs=2:normalize=0:duration=first[mix]`,
].join(";");

const loudnormTarget = `I=${targetIntegratedLufs}:TP=${truePeakCeilingDb}:LRA=11`;
const measurement = runFfmpeg([
  "-i", voicePath, "-i", musicPath,
  "-filter_complex", `${mixGraph};[mix]loudnorm=${loudnormTarget}:print_format=json[measured]`,
  "-map", "[measured]", "-f", "null", "-",
]);
// loudnorm prints its measurements as one flat JSON object of strings, last in its log.
const measured = JSON.parse(measurement.slice(measurement.lastIndexOf("{"), measurement.lastIndexOf("}") + 1)) as Record<string, string>;
const secondPass = [
  loudnormTarget,
  `measured_I=${measured.input_i}`,
  `measured_TP=${measured.input_tp}`,
  `measured_LRA=${measured.input_lra}`,
  `measured_thresh=${measured.input_thresh}`,
  `offset=${measured.target_offset}`,
  "linear=true",
].join(":");

runFfmpeg([
  "-y", "-i", voicePath, "-i", musicPath,
  "-filter_complex", `${mixGraph};[mix]loudnorm=${secondPass},aresample=48000[final]`,
  "-map", "0:v", "-map", "[final]", "-c:v", "copy", "-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart",
  outputPath,
]);
console.log(`voice ${voiceLufs} LUFS, music ${musicLufs} LUFS, music gain ${musicGainDb.toFixed(1)} dB, written to ${outputPath}`);
