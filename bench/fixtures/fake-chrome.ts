// A stand-in for headless Chrome, so sceneShots.test.ts can check how SceneCamera ends its Chrome without a real one.
// It takes the flags SceneCamera passes, writes the DevToolsActivePort file Chrome writes into its profile, records its
// pid in the file FAKE_CHROME_PID_FILE names, and then waits.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const profileFlag = process.argv.find((argument) => argument.startsWith("--user-data-dir="));
if (profileFlag === undefined || process.env.FAKE_CHROME_PID_FILE === undefined) {
  process.exit(3);
}
const profileDirectory = profileFlag.slice("--user-data-dir=".length);
mkdirSync(profileDirectory, { recursive: true });
writeFileSync(join(profileDirectory, "DevToolsActivePort"), "9222\n/devtools/browser/fake\n");
writeFileSync(process.env.FAKE_CHROME_PID_FILE, String(process.pid));
setInterval(() => undefined, 1_000);
