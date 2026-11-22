// Opens a SceneCamera and then waits, or throws, so sceneShots.test.ts can end this process in each way and see what
// happens to the Chrome it started. Argument 1 is "wait", "throw", or "close-on-stdin", which closes the camera when a
// line arrives on stdin, as judge.ts does after a run, and prints "closed" when that returns.
// With the fake Chrome's DevTools mode, "shoot" and "probe" run that call on its fake page, print the outcome as
// "shot <JSON>", "shot failed: <message>", or "probe <JSON>", close the camera, and exit.
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SceneCamera } from "../sceneShots.ts";

const camera = await SceneCamera.open("/nonexistent-three-assets");
console.log("opened");
if (process.argv[2] === "throw") {
  throw new Error("the judge run failed");
}
if (process.argv[2] === "close-on-stdin") {
  process.stdin.once("data", async () => {
    await camera.close();
    console.log("closed");
    process.exit(0);
  });
}
if (process.argv[2] === "shoot") {
  try {
    console.log(`shot ${JSON.stringify(await camera.shoot("<!DOCTYPE html><html></html>", "model", join(tmpdir(), "fake-shot.png")))}`);
  } catch (error) {
    console.log(`shot failed: ${error instanceof Error ? error.message : String(error)}`);
  }
  await camera.close();
  process.exit(0);
}
if (process.argv[2] === "probe") {
  console.log(`probe ${JSON.stringify(await camera.probe("<!DOCTYPE html><html></html>", "model"))}`);
  await camera.close();
  process.exit(0);
}
setInterval(() => undefined, 1_000);
