// Opens a SceneCamera and then waits, or throws, so sceneShots.test.ts can end this process in each way and see what
// happens to the Chrome it started. Argument 1 is "wait" or "throw".
import { SceneCamera } from "../sceneShots.ts";

await SceneCamera.open("/nonexistent-three-assets");
console.log("opened");
if (process.argv[2] === "throw") {
  throw new Error("the judge run failed");
}
setInterval(() => undefined, 1_000);
