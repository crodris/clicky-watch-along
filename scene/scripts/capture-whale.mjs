// Plays the built page over the real side-view diagram and saves one frame per
// camera stop to scene/shots. Run after build.mjs with: node scripts/capture-whale.mjs
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const sceneDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const pageFile = resolve(sceneDirectory, "../leanring-buddy/FieldTripScene.html");
const diagramFile = resolve(sceneDirectory, "fixtures/blue-whale-size.png");
const whaleSpec = JSON.parse(readFileSync(resolve(sceneDirectory, "fixtures/whale.json"), "utf8"));
const serverPort = 8802;
const cameraHoldMilliseconds = 1000;
const cameraMoveMilliseconds = 1800;
const labelFadeMilliseconds = 320;

const server = createServer((request, response) => {
  if (request.url === "/diagram.png") {
    response.writeHead(200, { "content-type": "image/png" });
    response.end(readFileSync(diagramFile));
    return;
  }
  response.writeHead(200, { "content-type": "text/html" });
  response.end(readFileSync(pageFile));
});
await new Promise((resolveListening) => server.listen(serverPort, "127.0.0.1", resolveListening));

const browser = await chromium.launch({
  channel: "chromium",
  args: ["--use-angle=metal", "--enable-gpu", "--ignore-gpu-blocklist"],
});
const context = await browser.newContext({
  viewport: { width: 1280, height: 800 },
  deviceScaleFactor: 2,
});
const page = await context.newPage();
const browserErrors = [];
page.on("pageerror", (error) => browserErrors.push(error.message));
page.on("console", (message) => {
  if (message.type() === "error" || message.type() === "warning") {
    browserErrors.push(message.text());
  }
});

await page.clock.install();
await page.goto(`http://127.0.0.1:${serverPort}/`);
await page.addStyleTag({
  content:
    "html:not(.without-page), html:not(.without-page) body { background: #ffffff url(/diagram.png) center / 100% auto no-repeat !important; }",
});
await page.waitForLoadState("networkidle");

// A screenshot with no page behind the canvas must have alpha 0 in the corners,
// or the macOS overlay would draw a box over the app beneath it.
async function assertCanvasCornersAreTransparent() {
  await page.evaluate(() => document.documentElement.classList.add("without-page"));
  const transparentShot = await page.screenshot({ omitBackground: true });
  await page.evaluate(() => document.documentElement.classList.remove("without-page"));
  const cornerAlphas = await page.evaluate(async (pngBase64) => {
    const pngBytes = Uint8Array.from(atob(pngBase64), (character) => character.charCodeAt(0));
    const bitmap = await createImageBitmap(new Blob([pngBytes], { type: "image/png" }));
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
    const context = canvas.getContext("2d", { willReadFrequently: true });
    context.drawImage(bitmap, 0, 0);
    return [
      [4, 4],
      [bitmap.width - 5, 4],
      [4, bitmap.height - 5],
      [bitmap.width - 5, bitmap.height - 5],
    ].map(([pixelX, pixelY]) => context.getImageData(pixelX, pixelY, 1, 1).data[3]);
  }, transparentShot.toString("base64"));
  if (cornerAlphas.some((alpha) => alpha !== 0)) {
    throw new Error(`Canvas is not transparent at the corners: ${cornerAlphas.join(", ")}`);
  }
  console.log("Canvas corners are fully transparent at stop 1.");
}

// CSS transitions run on real time, so the fake clock cannot skip them.
async function waitForLabelFade() {
  await new Promise((resolveWait) => setTimeout(resolveWait, labelFadeMilliseconds));
}

// The fake clock makes every shot land on an exact stop, however slowly the
// browser draws. Each move needs one tick to start and one to finish.
async function runCameraMove() {
  await page.clock.fastForward(cameraHoldMilliseconds + 1);
  await page.clock.fastForward(20);
  await page.clock.fastForward(cameraMoveMilliseconds + 20);
}

await page.evaluate((spec) => window.fieldTrip.play(spec), whaleSpec);
await page.clock.fastForward(20);
await waitForLabelFade();
await page.screenshot({ path: resolve(sceneDirectory, "shots/1-outside.png") });
await assertCanvasCornersAreTransparent();

await runCameraMove();
await waitForLabelFade();
await page.screenshot({ path: resolve(sceneDirectory, "shots/2-closer.png") });

await runCameraMove();
await waitForLabelFade();
await page.screenshot({ path: resolve(sceneDirectory, "shots/3-inside.png") });

const quizLabels = await page.evaluate(() =>
  [...document.querySelectorAll(".field-trip-label:not(.is-hidden)")].map((label) => label.textContent),
);
console.log(`Visible labels on the last frame: ${quizLabels.join(", ")}`);
console.log(browserErrors.length === 0 ? "No browser errors." : browserErrors.join("\n"));

await browser.close();
server.close();
if (browserErrors.some((message) => !message.includes("GPU stall"))) {
  process.exitCode = 1;
}
