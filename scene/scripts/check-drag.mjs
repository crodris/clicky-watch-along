// Drags the real built page with a real mouse and saves the extreme views to
// scene/shots. Run after build.mjs with: node scripts/check-drag.mjs
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const sceneDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const pageFile = resolve(sceneDirectory, "../leanring-buddy/FieldTripScene.html");
const whaleSpec = JSON.parse(readFileSync(resolve(sceneDirectory, "fixtures/whale.json"), "utf8"));
const serverPort = 8804;
const cameraHoldMilliseconds = 1000;
const cameraMoveMilliseconds = 1800;
const labelFadeMilliseconds = 320;

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
await new Promise((resolveListening) => server.listen(serverPort, "127.0.0.1", resolveListening));

const browser = await chromium.launch({
  channel: "chromium",
  args: ["--use-angle=metal", "--enable-gpu", "--ignore-gpu-blocklist"],
});
const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
const page = await context.newPage();
const browserErrors = [];
page.on("pageerror", (error) => browserErrors.push(error.message));

await page.clock.install();
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

async function labelPositions() {
  return page.evaluate(() =>
    [...document.querySelectorAll(".field-trip-label:not(.is-hidden)")]
      .map((label) => `${label.textContent} ${label.style.left} ${label.style.top}`)
      .join(" | "),
  );
}

await page.evaluate((spec) => window.fieldTrip.play(spec, false), whaleSpec);
await page.clock.fastForward(20);
await waitForLabelFade();

const labelsBeforeTheTourFinished = await labelPositions();
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
const labelsOfTheNextScene = await labelPositions();
await drag(300, 0);
assert((await labelPositions()) === labelsOfTheNextScene, "a new scene turns dragging off until its tour ends");

assert(browserErrors.length === 0, `no browser errors ${browserErrors.join(" ")}`);
await browser.close();
server.close();
