// Finds Clicky's blue triangle in a recording, so the edit's camera can follow it.
// Reads frames through ffmpeg at a low size and rate, keeps pixels close to the triangle's recorded color,
// and groups them into blobs. The triangle is a small compact blob. Its speech bubble, the same blue, sits just
// to its right; when the two merge at this size, the bubble's top-left corner is where the triangle is.
// Usage: node scripts/track-cursor.ts <recording.mov> <out.json>
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";

const [recordingPath, outputPath] = process.argv.slice(2);
if (!recordingPath || !outputPath) {
  console.error("usage: node scripts/track-cursor.ts <recording.mov> <out.json>");
  process.exit(2);
}

const sampleWidth = 960;
const sampleHeight = 540;
const samplesPerSecond = 10;
const frameByteCount = sampleWidth * sampleHeight * 3;

type Blob = { area: number; centerX: number; centerY: number; width: number; height: number; left: number; top: number };
type CursorSample = { seconds: number; x: number; y: number } | { seconds: number; x: null; y: null };

// #3380FF records as about (64, 120, 240) on the MacBook's built-in display, and as about (1, 117, 242) on the
// external monitor, after each display's color conversion.
function isTriangleBlue(red: number, green: number, blue: number): boolean {
  return red < 90 && green > 95 && green < 145 && blue > 215;
}

/** Blobs of matching pixels, each with its pixel count and bounding box. */
function blueBlobs(frame: Buffer): Blob[] {
  const visited = new Uint8Array(sampleWidth * sampleHeight);
  const blobs: Blob[] = [];
  const stack: number[] = [];
  for (let pixelIndex = 0; pixelIndex < sampleWidth * sampleHeight; pixelIndex++) {
    if (visited[pixelIndex]) continue;
    visited[pixelIndex] = 1;
    const byteIndex = pixelIndex * 3;
    if (!isTriangleBlue(frame[byteIndex]!, frame[byteIndex + 1]!, frame[byteIndex + 2]!)) continue;
    let area = 0, sumX = 0, sumY = 0, minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
    stack.push(pixelIndex);
    while (stack.length > 0) {
      const current = stack.pop()!;
      const currentX = current % sampleWidth, currentY = Math.floor(current / sampleWidth);
      area++; sumX += currentX; sumY += currentY;
      minX = Math.min(minX, currentX); maxX = Math.max(maxX, currentX); minY = Math.min(minY, currentY); maxY = Math.max(maxY, currentY);
      for (const [stepX, stepY] of [[1, 0], [-1, 0], [0, 1], [0, -1]] as const) {
        const neighborX = currentX + stepX, neighborY = currentY + stepY;
        if (neighborX < 0 || neighborY < 0 || neighborX >= sampleWidth || neighborY >= sampleHeight) continue;
        const neighbor = neighborY * sampleWidth + neighborX;
        if (visited[neighbor]) continue;
        visited[neighbor] = 1;
        const neighborByte = neighbor * 3;
        if (isTriangleBlue(frame[neighborByte]!, frame[neighborByte + 1]!, frame[neighborByte + 2]!)) stack.push(neighbor);
      }
    }
    blobs.push({ area, centerX: sumX / area, centerY: sumY / area, width: maxX - minX + 1, height: maxY - minY + 1, left: minX, top: minY });
  }
  return blobs;
}

const ffmpeg = spawn("ffmpeg", ["-loglevel", "error", "-i", recordingPath, "-vf", `fps=${samplesPerSecond},scale=${sampleWidth}:${sampleHeight}`, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]);
let pending = Buffer.alloc(0);
const samples: CursorSample[] = [];
let lastPosition: { x: number; y: number } | null = null;

ffmpeg.stdout.on("data", (chunk: Buffer) => {
  pending = Buffer.concat([pending, chunk]);
  while (pending.length >= frameByteCount) {
    const frame = pending.subarray(0, frameByteCount);
    pending = pending.subarray(frameByteCount);
    const seconds = samples.length / samplesPerSecond;
    // The triangle covers roughly 10 to 60 pixels at this sampling size, from either display.
    // A bubble is wide and short; its top-left corner stands in for a triangle that merged into it.
    const blobs = blueBlobs(frame);
    const triangles = blobs.filter((blob) => blob.area >= 8 && blob.area <= 70 && blob.width <= 12 && blob.height <= 12);
    const bubbleCorners = blobs
      .filter((blob) => blob.width >= 40 && blob.height >= 8 && blob.height <= 60)
      .map((blob) => ({ ...blob, centerX: blob.left + 3, centerY: blob.top + 3 }));
    const candidates = triangles.length > 0 ? triangles : bubbleCorners;
    if (candidates.length === 0) {
      samples.push({ seconds, x: null, y: null });
      continue;
    }
    const chosen = lastPosition
      ? candidates.reduce((best, blob) => (Math.hypot(blob.centerX - lastPosition!.x, blob.centerY - lastPosition!.y) < Math.hypot(best.centerX - lastPosition!.x, best.centerY - lastPosition!.y) ? blob : best))
      : candidates.reduce((best, blob) => (blob.area > best.area ? blob : best));
    lastPosition = { x: chosen.centerX, y: chosen.centerY };
    samples.push({ seconds, x: chosen.centerX / sampleWidth, y: chosen.centerY / sampleHeight });
  }
});

ffmpeg.on("close", (exitCode) => {
  if (exitCode !== 0) {
    console.error(`ffmpeg exited with ${exitCode}`);
    process.exit(1);
  }
  const foundCount = samples.filter((sample) => sample.x !== null).length;
  writeFileSync(outputPath, JSON.stringify({ samplesPerSecond, samples }, null, 0));
  console.log(`${samples.length} samples, triangle found in ${foundCount}, written to ${outputPath}`);
});
