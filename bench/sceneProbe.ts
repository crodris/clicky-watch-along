// Loads saved /live-scene pages in headless Chrome and drives each through the contract the app uses (sceneShots.ts's
// probe), then prints one JSON line per page. With --shots <dir> it also writes the judge's side-by-side screenshot.
// A page whose file name holds "simulation-" is probed as a simulation, so a run at each end of its first control shows
// whether its readouts follow the controls.
//
//   node bench/sceneProbe.ts [--shots <dir>] <page.html> ...
import { mkdirSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";
import { SceneCamera } from "./sceneShots.ts";

const argumentsAfterTheScript = process.argv.slice(2);
const shotsFlagIndex = argumentsAfterTheScript.indexOf("--shots");
const shotsDirectory = shotsFlagIndex === -1 ? undefined : argumentsAfterTheScript[shotsFlagIndex + 1];
const pagePaths = argumentsAfterTheScript.filter((_, index) => shotsFlagIndex === -1 || (index !== shotsFlagIndex && index !== shotsFlagIndex + 1));
if (pagePaths.length === 0) {
  console.error("Usage: node bench/sceneProbe.ts [--shots <dir>] <page.html> ...");
  process.exit(1);
}
if (shotsDirectory !== undefined) mkdirSync(shotsDirectory, { recursive: true });

const sceneCamera = await SceneCamera.open(join(import.meta.dirname, "..", "leanring-buddy", "LiveSceneAssets"));
try {
  for (const pagePath of pagePaths) {
    const html = readFileSync(pagePath, "utf8");
    const sceneKind = basename(pagePath).includes("simulation-") ? "simulation" : "model";
    const probe = await sceneCamera.probe(html, sceneKind);
    const shot = shotsDirectory === undefined ? undefined : await sceneCamera.shoot(html, sceneKind, join(shotsDirectory, basename(pagePath).replace(/\.html$/, ".png")));
    console.log(JSON.stringify({ page: basename(pagePath), sceneKind, ...probe, ...(shot === undefined ? {} : { secondShot: shot.secondShot }) }));
  }
} finally {
  await sceneCamera.close();
}
