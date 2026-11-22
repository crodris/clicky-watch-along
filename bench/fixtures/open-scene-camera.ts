// Opens a SceneCamera and then waits, or throws, so sceneShots.test.ts can end this process in each way and see what
// happens to the Chrome it started. Argument 1 is "wait", "throw", or "close-on-stdin", which closes the camera when a
// line arrives on stdin, as judge.ts does after a run, and prints "closed" when that returns.
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
setInterval(() => undefined, 1_000);
