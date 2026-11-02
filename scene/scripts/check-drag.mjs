// Drags and zooms the real built page and saves the extreme views to
// scene/shots. Run after build.mjs with: node scripts/check-drag.mjs
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const sceneDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const pageFile = resolve(sceneDirectory, "../leanring-buddy/FieldTripScene.html");
const whaleSpec = JSON.parse(readFileSync(resolve(sceneDirectory, "fixtures/whale.json"), "utf8"));
const cameraHoldMilliseconds = 1000;
const cameraMoveMilliseconds = 1800;
const labelFadeMilliseconds = 320;
const gestureSettleMilliseconds = 150;
const maximumMedianGestureFrameMilliseconds = 150;
const retinaViewport = { width: 1710, height: 1107 };
const retinaDeviceScaleFactor = 2;
const gestureFrameCount = 40;

function assert(condition, message) {
  if (!condition) {
    throw new Error(`FAILED: ${message}`);
  }
  console.log(`ok: ${message}`);
}

const server = createServer((_request, response) => {
  response.writeHead(200, { "content-type": "text/html" });
  response.end(readFileSync(pageFile));
});
await new Promise((resolveListening) => server.listen(0, "127.0.0.1", resolveListening));
// Port 0 lets the OS pick a free port, so two runs at once do not collide.
const serverPort = server.address().port;

const browser = await chromium.launch({
  channel: "chromium",
  args: ["--use-angle=metal", "--enable-gpu", "--ignore-gpu-blocklist"],
});
const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
const page = await context.newPage();
const browserErrors = [];
page.on("pageerror", (error) => browserErrors.push(error.message));

await page.clock.install();
// Only fastForward moves time, so the real seconds a slow machine spends on
// each step cannot start the next camera move early.
await page.clock.pauseAt(new Date(Date.now() + 1000));
await page.goto(`http://127.0.0.1:${serverPort}/`);
await page.addStyleTag({ content: "html, body { background: #ffffff !important; }" });

async function waitForLabelFade() {
  await new Promise((resolveWait) => setTimeout(resolveWait, labelFadeMilliseconds));
}

async function runCameraMove() {
  await page.clock.fastForward(cameraHoldMilliseconds + 1);
  await page.clock.fastForward(20);
  await page.clock.fastForward(cameraMoveMilliseconds + 20);
}

async function drag(deltaX, deltaY) {
  await page.mouse.move(640, 400);
  await page.mouse.down();
  await page.mouse.move(640 + deltaX, 400 + deltaY, { steps: 12 });
  await page.mouse.up();
  await page.clock.fastForward(20);
  await waitForLabelFade();
}

async function zoom(magnification) {
  await page.evaluate((amount) => window.fieldTrip.zoomBy(amount), magnification);
  await page.clock.fastForward(20);
}

// Labels spread apart when the camera moves closer to the model.
async function labelSpreadPixels() {
  return page.evaluate(() => {
    const lefts = [...document.querySelectorAll(".field-trip-label:not(.is-hidden)")].map((label) =>
      Number.parseFloat(label.style.left),
    );
    return Math.max(...lefts) - Math.min(...lefts);
  });
}

async function labelPositions() {
  return page.evaluate(() =>
    [...document.querySelectorAll(".field-trip-label:not(.is-hidden)")]
      .map((label) => `${label.textContent} ${label.style.left} ${label.style.top}`)
      .join(" | "),
  );
}

// Uses the real clock, because the cost being measured is the GPU work of each frame.
async function measureGesturesOnARetinaScreen() {
  const retinaContext = await browser.newContext({
    viewport: retinaViewport,
    deviceScaleFactor: retinaDeviceScaleFactor,
  });
  const retinaPage = await retinaContext.newPage();
  retinaPage.on("pageerror", (error) => browserErrors.push(error.message));
  await retinaPage.addInitScript(() => {
    window.tourFinished = new Promise((resolveTour) => {
      window.webkit = { messageHandlers: { fieldTripEvent: { postMessage: resolveTour } } };
    });
  });
  await retinaPage.goto(`http://127.0.0.1:${serverPort}/`);
  await retinaPage.evaluate((spec) => window.fieldTrip.play(spec, false), whaleSpec);
  await retinaPage.evaluate(() => window.tourFinished);
  const canvasWidth = () => retinaPage.evaluate(() => document.querySelector("canvas").width);
  const fullCanvasWidth = retinaViewport.width * retinaDeviceScaleFactor;
  await new Promise((resolveWait) => setTimeout(resolveWait, gestureSettleMilliseconds * 2));
  assert((await canvasWidth()) === fullCanvasWidth, "a finished scene renders at full pixel ratio");

  const frameMilliseconds = await retinaPage.evaluate(async (frameCount) => {
    const nextFrame = () => new Promise((resolveFrame) => requestAnimationFrame(resolveFrame));
    const dispatchPointer = (type, clientX) =>
      window.dispatchEvent(new PointerEvent(type, { clientX, clientY: 500, bubbles: true }));
    const intervals = [];
    const gl = document.querySelector("canvas").getContext("webgl2");
    // Frames queue ahead of the GPU, so the gap between animation frames hides
    // the cost. Reading one pixel waits until the frame has really finished.
    const waitForGpuToFinish = () => gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(4));
    dispatchPointer("pointerdown", 600);
    await nextFrame();
    waitForGpuToFinish();
    for (let frameIndex = 0; frameIndex < frameCount; frameIndex += 1) {
      const frameStartedAt = performance.now();
      dispatchPointer("pointermove", 600 + (frameIndex + 1) * 6);
      await nextFrame();
      waitForGpuToFinish();
      intervals.push(performance.now() - frameStartedAt);
    }
    window.gestureCanvasWidth = document.querySelector("canvas").width;
    dispatchPointer("pointerup", 600);
    return intervals;
  }, gestureFrameCount);
  const sortedFrameMilliseconds = [...frameMilliseconds].sort((left, right) => left - right);
  const medianFrameMilliseconds = sortedFrameMilliseconds[Math.floor(sortedFrameMilliseconds.length / 2)];
  console.log(
    `median gesture frame: ${medianFrameMilliseconds.toFixed(1)} ms over ${frameMilliseconds.length} frames at ` +
      `${retinaViewport.width}x${retinaViewport.height} @${retinaDeviceScaleFactor}x`,
  );
  console.log(`slowest gesture frame: ${sortedFrameMilliseconds.at(-1).toFixed(1)} ms`);
  assert(
    medianFrameMilliseconds < maximumMedianGestureFrameMilliseconds,
    `median gesture frame is under ${maximumMedianGestureFrameMilliseconds} ms`,
  );
  assert(
    (await retinaPage.evaluate(() => window.gestureCanvasWidth)) === retinaViewport.width,
    "a drag renders at pixel ratio 1",
  );

  await new Promise((resolveWait) => setTimeout(resolveWait, gestureSettleMilliseconds * 3));
  assert((await canvasWidth()) === fullCanvasWidth, "the canvas returns to full pixel ratio after a drag settles");

  await retinaPage.evaluate(() => window.fieldTrip.zoomBy(0.2));
  await new Promise((resolveWait) => setTimeout(resolveWait, 50));
  assert((await canvasWidth()) === retinaViewport.width, "a zoom renders at pixel ratio 1");
  await new Promise((resolveWait) => setTimeout(resolveWait, gestureSettleMilliseconds * 3));
  assert((await canvasWidth()) === fullCanvasWidth, "the canvas returns to full pixel ratio after a zoom settles");

  await retinaPage.evaluate((spec) => {
    window.fieldTrip.zoomBy(0.2);
    window.fieldTrip.play(spec, false);
  }, whaleSpec);
  assert((await canvasWidth()) === fullCanvasWidth, "a new scene starts at full pixel ratio even mid-gesture");
  await retinaContext.close();
}

await page.evaluate((spec) => window.fieldTrip.play(spec, false), whaleSpec);
await page.clock.fastForward(20);
await waitForLabelFade();

const labelsBeforeTheTourFinished = await labelPositions();
await zoom(0.3);
assert(
  (await labelPositions()) === labelsBeforeTheTourFinished,
  "a zoom during the tour does not move the camera",
);
await drag(300, 0);
assert(
  (await labelPositions()) === labelsBeforeTheTourFinished,
  "a drag during the tour does not move the camera",
);

await runCameraMove();
await runCameraMove();
await waitForLabelFade();
await page.screenshot({ path: resolve(sceneDirectory, "shots/drag-0-rest.png") });
const labelsAtRest = await labelPositions();

await page.mouse.move(640, 400);
await page.mouse.move(900, 500, { steps: 6 });
assert((await labelPositions()) === labelsAtRest, "moving the mouse with no button held does nothing");

await drag(400, 0);
const labelsAfterDrag = await labelPositions();
assert(labelsAfterDrag !== labelsAtRest, "a drag on a finished scene moves the camera");

await page.mouse.move(640, 400);
await page.mouse.move(900, 500, { steps: 6 });
assert((await labelPositions()) === labelsAfterDrag, "the drag ends when the button is released");

await page.screenshot({ path: resolve(sceneDirectory, "shots/drag-1-azimuth-max.png") });
await drag(-400, 0);
await drag(-400, 0);
await page.screenshot({ path: resolve(sceneDirectory, "shots/drag-2-azimuth-min.png") });
await drag(400, 300);
await page.screenshot({ path: resolve(sceneDirectory, "shots/drag-3-polar-max.png") });
await drag(0, -300);
await drag(0, -300);
await page.screenshot({ path: resolve(sceneDirectory, "shots/drag-4-polar-min.png") });

await drag(4000, 0);
const labelsAtTheLimit = await labelPositions();
await drag(4000, 0);
assert((await labelPositions()) === labelsAtTheLimit, "a drag stops at the orbit limit");

await page.evaluate((spec) => window.fieldTrip.play(spec, false), whaleSpec);
await page.clock.fastForward(20);
await waitForLabelFade();
await runCameraMove();
await runCameraMove();
await waitForLabelFade();
const labelsBeforeZoom = await labelPositions();
const spreadBeforeZoom = await labelSpreadPixels();

await zoom(0.2);
const labelsZoomedIn = await labelPositions();
assert(labelsZoomedIn !== labelsBeforeZoom, "zooming in on a finished scene moves the labels");
const spreadZoomedIn = await labelSpreadPixels();
assert(spreadZoomedIn > spreadBeforeZoom, "a positive magnification moves the camera closer");
await page.screenshot({ path: resolve(sceneDirectory, "shots/zoom-1-in.png") });

await zoom(-0.5);
const labelsZoomedOut = await labelPositions();
assert(
  labelsZoomedOut !== labelsZoomedIn && labelsZoomedOut !== labelsBeforeZoom,
  "zooming out on a finished scene moves the labels",
);
assert((await labelSpreadPixels()) < spreadZoomedIn, "a negative magnification moves the camera away");

for (let pinchIndex = 0; pinchIndex < 12; pinchIndex += 1) {
  await zoom(0.9);
}
const labelsAtClosestZoom = await labelPositions();
await page.screenshot({ path: resolve(sceneDirectory, "shots/zoom-2-closest.png") });
await zoom(0.9);
assert((await labelPositions()) === labelsAtClosestZoom, "zooming in stops at the closest limit");

for (let pinchIndex = 0; pinchIndex < 12; pinchIndex += 1) {
  await zoom(-0.9);
}
const labelsAtFarthestZoom = await labelPositions();
await page.screenshot({ path: resolve(sceneDirectory, "shots/zoom-3-farthest.png") });
await zoom(-0.9);
assert((await labelPositions()) === labelsAtFarthestZoom, "zooming out stops at the farthest limit");

await page.evaluate((spec) => window.fieldTrip.play(spec, false), whaleSpec);
await page.clock.fastForward(20);
await waitForLabelFade();
const labelsOfTheNextScene = await labelPositions();
await drag(300, 0);
assert((await labelPositions()) === labelsOfTheNextScene, "a new scene turns dragging off until its tour ends");

await zoom(0.3);
assert((await labelPositions()) === labelsOfTheNextScene, "a new scene turns zooming off until its tour ends");

await measureGesturesOnARetinaScreen();

assert(browserErrors.length === 0, `no browser errors ${browserErrors.join(" ")}`);
await browser.close();
server.close();
