import { Config } from "@remotion/cli/config";

// Remotion's downloaded headless shell (Chrome 157) hangs at "Waiting for root component to load" on Chris's Mac,
// in this project and in others. Setting this to another Chromium, such as Playwright's headless shell, works.
const browserExecutable = process.env.REMOTION_BROWSER_EXECUTABLE;
if (browserExecutable) Config.setBrowserExecutable(browserExecutable);
