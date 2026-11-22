import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { aChromeOnTheFolderHasALiveParent, pageWithLocalThree, sceneShotsChromeProcesses, sceneShotsFolderIsStale, scenePageContentSecurityPolicy } from "./sceneShots.ts";

describe("pageWithLocalThree", () => {
  it("points the import map's three.js at the local server, and leaves every other URL alone", () => {
    const page = '<script type="importmap">{ "imports": { "three": "clicky-asset://three/three.module.js" } }</script><img src="https://example.com/a.png">';

    assert.equal(
      pageWithLocalThree(page),
      '<script type="importmap">{ "imports": { "three": "/three/three.module.js" } }</script><img src="https://example.com/a.png">',
    );
  });
});

describe("scenePageContentSecurityPolicy", () => {
  it("lets a page load only from this server, so it cannot call a local Worker that holds API keys", () => {
    const directives = new Map(
      scenePageContentSecurityPolicy.split(";").map((directive) => {
        const [name = "", ...sources] = directive.trim().split(/\s+/);
        return [name, sources] as const;
      }),
    );

    assert.deepEqual(directives.get("default-src"), ["'none'"]);
    assert.deepEqual(directives.get("connect-src"), ["'self'"]);
    assert.deepEqual(directives.get("webrtc"), ["'block'"]);
    assert.ok(!scenePageContentSecurityPolicy.includes("http"), "names no other host");
  });
});

describe("sceneShotsChromeProcesses", () => {
  const profile = "--user-data-dir=/var/folders/ab/T/scene-shots-9XaGV9/chrome-profile";

  it("finds a headless Chrome and its helpers on a scene-shots profile, and nothing else", () => {
    const psOutput = [
      `83128     1 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new --remote-debugging-port=0 ${profile} --window-size=1280,800`,
      `83177 83128 /Applications/Google Chrome.app/Contents/Frameworks/Helpers/Google Chrome Helper --type=gpu-process --headless ${profile}`,
      // A Chrome with a window, even one pointed at a scene-shots folder by hand, is not a leftover of the judge.
      `90003  4000 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome ${profile}`,
      // Chris's own Chrome has a window, so it has no --headless flag.
      "35023     1 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      // Other headless Chromes, such as the judge's screenshot runs and Remotion's, keep their own profiles.
      "90001  4000 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new --user-data-dir=/Users/c/bench/out/chrome-profile",
      // A scene-shots path outside the profile flag, such as in an argument to another program, is not a Chrome profile.
      "90002  4000 grep --headless scene-shots-9XaGV9",
    ].join("\n");

    assert.deepEqual(sceneShotsChromeProcesses(psOutput), [
      { pid: 83128, parentPid: 1, scratchDirectory: "/var/folders/ab/T/scene-shots-9XaGV9" },
      { pid: 83177, parentPid: 83128, scratchDirectory: "/var/folders/ab/T/scene-shots-9XaGV9" },
    ]);
  });
});

describe("aChromeOnTheFolderHasALiveParent", () => {
  const folder = "/var/folders/ab/T/scene-shots-9XaGV9";

  it("is false for an orphaned Chrome even though its helpers have the Chrome as their parent", () => {
    assert.equal(
      aChromeOnTheFolderHasALiveParent([
        { pid: 83128, parentPid: 1, scratchDirectory: folder },
        { pid: 83177, parentPid: 83128, scratchDirectory: folder },
      ]),
      false,
    );
  });

  it("is true for a Chrome whose run is still its parent", () => {
    assert.equal(
      aChromeOnTheFolderHasALiveParent([
        { pid: 83128, parentPid: 4000, scratchDirectory: folder },
        { pid: 83177, parentPid: 83128, scratchDirectory: folder },
      ]),
      true,
    );
  });

  it("is false with no Chrome on the folder", () => {
    assert.equal(aChromeOnTheFolderHasALiveParent([]), false);
  });
});

describe("sceneShotsFolderIsStale", () => {
  const alive = (pid: number) => pid === 100;

  it("is stale only when the owner process is gone", () => {
    assert.equal(sceneShotsFolderIsStale("100", 10 * 60_000, alive, false), false);
    assert.equal(sceneShotsFolderIsStale("200", 1_000, alive, false), true);
  });

  it("gives a folder with no usable owner file a minute before calling it stale", () => {
    assert.equal(sceneShotsFolderIsStale(undefined, 1_000, alive, false), false);
    assert.equal(sceneShotsFolderIsStale(undefined, 61_000, alive, false), true);
    assert.equal(sceneShotsFolderIsStale("not a pid", 61_000, alive, false), true);
  });

  it("keeps a folder with no owner file while a Chrome on it has a live parent, such as a run on older code", () => {
    assert.equal(sceneShotsFolderIsStale(undefined, 10 * 60_000, alive, true), false);
  });
});

/** The fake or real Chromes that run on a scene-shots folder inside `folder`, found by their profile path in `ps`. */
function chromesInside(folder: string) {
  return sceneShotsChromeProcesses(execFileSync("ps", ["-axo", "pid=,ppid=,command="], { encoding: "utf8" })).filter((chromeProcess) =>
    chromeProcess.scratchDirectory.startsWith(`${folder}/`),
  );
}

/**
 * Ends every process a test suite started, before the suite deletes its folder. A driver is killed by its pid. A Chrome
 * that a driver started is found by its profile folder instead, since a suite that times out while a camera opens has
 * no pid file for it yet: on 2026-11-21 such a fake Chrome outlived its run by 7 hours, after it made the deleted
 * folder again to write its pid file.
 */
function endEveryProcessInside(folder: string, startedProcessIds: Iterable<number>) {
  for (const processId of startedProcessIds) {
    try {
      process.kill(processId, "SIGKILL");
    } catch {
      // It already ended.
    }
  }
  for (const chromeProcess of chromesInside(folder)) {
    try {
      process.kill(chromeProcess.pid, "SIGKILL");
    } catch {
      // It already ended.
    }
  }
}

// Each test runs fixtures/open-scene-camera.ts with fixtures/fake-chrome.ts as Chrome, in a temporary TMPDIR of its own
// (see openCamera). The fake Chrome is a node process, so its flags show in `ps` like Chrome's. A process that ignores
// its signal would hang a test forever, so each test has a timeout that fails it instead.
describe("SceneCamera ends its Chrome", { timeout: 30_000 }, () => {
  let sandbox = "";
  // Every process a test starts, so a failed assertion leaves nothing running to hold the test run open.
  const startedProcessIds = new Set<number>();
  before(() => {
    sandbox = mkdtempSync(join(tmpdir(), "scene-camera-test-"));
  });
  after(() => {
    endEveryProcessInside(sandbox, startedProcessIds);
    rmSync(sandbox, { recursive: true, force: true });
  });

  const isAlive = (pid: number) => {
    try {
      process.kill(pid, 0);
      return true;
    } catch {
      return false;
    }
  };

  function startTheDriver(name: string, argument: "wait" | "throw" | "close-on-stdin") {
    const pidFile = join(sandbox, `${name}.pid`);
    const fakeChromeLauncher = join(sandbox, `${name}-chrome`);
    // CHROME_PATH is one executable, so a small script starts the fake Chrome with the flags SceneCamera gives it.
    writeFileSync(fakeChromeLauncher, `#!/bin/sh\nexec node ${join(import.meta.dirname, "fixtures", "fake-chrome.ts")} "$@"\n`);
    chmodSync(fakeChromeLauncher, 0o755);
    const driver: ChildProcess = spawn("node", [join(import.meta.dirname, "fixtures", "open-scene-camera.ts"), argument], {
      env: { ...process.env, TMPDIR: sandbox, CHROME_PATH: fakeChromeLauncher, FAKE_CHROME_PID_FILE: pidFile },
      // The throw case prints its stack trace to stderr, which the test run does not need to show.
      stdio: ["pipe", "pipe", "ignore"],
    });
    if (driver.pid !== undefined) {
      startedProcessIds.add(driver.pid);
    }
    return { driver, pidFile };
  }

  async function openCamera(name: string, argument: "wait" | "throw" | "close-on-stdin") {
    const { driver, pidFile } = startTheDriver(name, argument);
    const exited = new Promise<void>((resolve) => driver.once("exit", () => resolve()));
    let output = "";
    await new Promise<void>((resolve, reject) => {
      driver.stdout?.on("data", (chunk) => {
        output += String(chunk);
        if (output.includes("opened")) {
          resolve();
        }
      });
      driver.once("exit", () => reject(new Error("the driver ended before it opened the camera")));
    }).catch((error) => {
      if (argument !== "throw") {
        throw error;
      }
    });
    const fakeChromePid = Number(readFileSync(pidFile, "utf8"));
    startedProcessIds.add(fakeChromePid);
    return { driver, exited, fakeChromePid, output: () => output };
  }

  const scratchFolders = () => readdirSync(sandbox).filter((name) => name.startsWith("scene-shots-"));

  async function waitUntil(condition: () => boolean) {
    for (let attempt = 0; attempt < 40 && !condition(); attempt += 1) {
      await sleep(100);
    }
  }

  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
    it(`kills Chrome and deletes its folder when the process gets ${signal}`, async () => {
      const { driver, exited, fakeChromePid } = await openCamera(`signal-${signal}`, "wait");
      assert.equal(isAlive(fakeChromePid), true);

      driver.kill(signal);
      await exited;
      await waitUntil(() => !isAlive(fakeChromePid));

      assert.equal(isAlive(fakeChromePid), false);
      assert.deepEqual(scratchFolders(), []);
    });
  }

  it("kills Chrome and deletes its folder when the process dies of an uncaught error", async () => {
    const { exited, fakeChromePid } = await openCamera("throw", "throw");
    await exited;
    await waitUntil(() => !isAlive(fakeChromePid));

    assert.equal(isAlive(fakeChromePid), false);
    assert.deepEqual(scratchFolders(), []);
  });

  it("cannot catch SIGKILL, so the next run kills the Chrome that was left and deletes its folder", async () => {
    // A second run that is still going, which the next run must leave alone.
    const keeper = await openCamera("sigkill-keeper", "wait");
    const left = await openCamera("sigkill-left", "wait");
    left.driver.kill("SIGKILL");
    await left.exited;
    assert.equal(isAlive(left.fakeChromePid), true, "a SIGKILL leaves Chrome running, which the next run has to clean up");
    assert.equal(scratchFolders().length, 2);

    const next = await openCamera("sigkill-next", "wait");
    await waitUntil(() => !isAlive(left.fakeChromePid));

    assert.equal(isAlive(left.fakeChromePid), false);
    assert.equal(isAlive(keeper.fakeChromePid), true, "a run that is still going keeps its Chrome");
    assert.equal(isAlive(next.fakeChromePid), true, "the new run keeps its own Chrome");
    assert.equal(scratchFolders().length, 2, "the left folder is gone, and the two running folders stay");
    assert.equal(existsSync(join(sandbox, scratchFolders()[0] ?? "", "owner-pid")), true);

    keeper.driver.kill("SIGTERM");
    next.driver.kill("SIGTERM");
    await Promise.all([keeper.exited, next.exited]);
  });

  it("closes without waiting forever when Chrome already exited, as after a crash mid-run", async () => {
    const { driver, exited, fakeChromePid, output } = await openCamera("crashed-chrome", "close-on-stdin");
    process.kill(fakeChromePid, "SIGKILL");
    await waitUntil(() => !isAlive(fakeChromePid));

    driver.stdin?.write("close\n");
    await exited;

    assert.match(output(), /closed/);
    assert.deepEqual(scratchFolders(), []);
  });

  /** Makes a run's folder look like one from before the owner file existed, and old enough to be past the grace period. */
  function makeItLookLikeOlderCode(scratchFolderName: string) {
    rmSync(join(sandbox, scratchFolderName, "owner-pid"));
    const tenMinutesAgo = new Date(Date.now() - 10 * 60_000);
    utimesSync(join(sandbox, scratchFolderName), tenMinutesAgo, tenMinutesAgo);
  }

  it("leaves the Chrome of a run on older code, which wrote no owner file, while its run is still going", async () => {
    const olderCodeRun = await openCamera("older-code-live", "wait");
    makeItLookLikeOlderCode(scratchFolders()[0] ?? "");

    const next = await openCamera("older-code-next", "wait");

    assert.equal(isAlive(olderCodeRun.fakeChromePid), true);
    assert.equal(scratchFolders().length, 2);
    olderCodeRun.driver.kill("SIGTERM");
    next.driver.kill("SIGTERM");
    await Promise.all([olderCodeRun.exited, next.exited]);
  });

  it("ends a Chrome that is still starting when the suite cleans up, so a suite that times out leaves none running", async () => {
    const { driver } = startTheDriver("still-starting", "wait");
    for (let attempt = 0; attempt < 100 && chromesInside(sandbox).length === 0; attempt += 1) {
      await sleep(100);
    }
    assert.notDeepEqual(chromesInside(sandbox), [], "the driver started no Chrome");

    // The cleanup knows only the driver, as when the suite's timeout ends it before the pid file is read.
    endEveryProcessInside(sandbox, driver.pid === undefined ? [] : [driver.pid]);
    await waitUntil(() => chromesInside(sandbox).length === 0);

    assert.deepEqual(chromesInside(sandbox), []);
    // A SIGKILLed driver leaves its folder, which the tests after this one would count.
    for (const scratchFolder of scratchFolders()) {
      rmSync(join(sandbox, scratchFolder), { recursive: true, force: true });
    }
  });

  it("kills the Chrome that a SIGKILLed run on older code left, which is how the 3.5 hour leak happened", async () => {
    const olderCodeRun = await openCamera("older-code-killed", "wait");
    makeItLookLikeOlderCode(scratchFolders()[0] ?? "");
    olderCodeRun.driver.kill("SIGKILL");
    await olderCodeRun.exited;

    const next = await openCamera("older-code-cleaner", "wait");
    await waitUntil(() => !isAlive(olderCodeRun.fakeChromePid));

    assert.equal(isAlive(olderCodeRun.fakeChromePid), false);
    assert.equal(scratchFolders().length, 1);
    next.driver.kill("SIGTERM");
    await next.exited;
  });
});

describe("SceneCamera drives a page through the fake Chrome's DevTools", { timeout: 60_000 }, () => {
  let sandbox = "";
  before(() => {
    sandbox = mkdtempSync(join(tmpdir(), "scene-camera-devtools-test-"));
  });
  const startedDriverIds = new Set<number>();
  after(() => {
    endEveryProcessInside(sandbox, startedDriverIds);
    rmSync(sandbox, { recursive: true, force: true });
  });

  // Runs the driver with one call on the fake page, each run in its own temporary folder, and returns what it printed.
  async function runTheDriver(name: string, call: "shoot" | "probe", fakeChromeSettings: Record<string, string>): Promise<string> {
    const runFolder = join(sandbox, name);
    mkdirSync(runFolder);
    const fakeChromeLauncher = join(runFolder, "chrome");
    writeFileSync(fakeChromeLauncher, `#!/bin/sh\nexec node ${join(import.meta.dirname, "fixtures", "fake-chrome.ts")} "$@"\n`);
    chmodSync(fakeChromeLauncher, 0o755);
    const driver = spawn("node", [join(import.meta.dirname, "fixtures", "open-scene-camera.ts"), call], {
      env: { ...process.env, TMPDIR: runFolder, CHROME_PATH: fakeChromeLauncher, FAKE_CHROME_PID_FILE: join(runFolder, "chrome.pid"), FAKE_CHROME_DEVTOOLS: "1", ...fakeChromeSettings },
      stdio: ["ignore", "pipe", "ignore"],
    });
    if (driver.pid !== undefined) {
      startedDriverIds.add(driver.pid);
    }
    let output = "";
    driver.stdout?.on("data", (chunk) => {
      output += String(chunk);
    });
    await new Promise<void>((resolve) => driver.once("exit", () => resolve()));
    return output;
  }

  it("tries a refused screenshot capture again, so two refusals in a row still give the picture", async () => {
    const output = await runTheDriver("two-refusals", "shoot", { FAKE_CHROME_CAPTURE_FAILURES: "2" });

    assert.match(output, /^shot \{.*"secondShot":"after a half turn"/m);
  });

  it("gives up on the third refusal in a row, and says why", async () => {
    const output = await runTheDriver("three-refusals", "shoot", { FAKE_CHROME_CAPTURE_FAILURES: "3" });

    assert.match(output, /^shot failed: Page\.captureScreenshot: Unable to capture screenshot$/m);
  });

  it("probes a page with no focusPart and still reports the tour, the page's errors, and what the page lacks", async () => {
    const output = await runTheDriver("probe-no-focus-part", "probe", { FAKE_CHROME_PAGE_ERROR: "TypeError: parts is not iterable\n    at stepTour" });
    const probeLine = output.split("\n").find((line) => line.startsWith("probe "));
    assert.ok(probeLine !== undefined, `the driver printed no probe line: ${output}`);

    // JSON.parse returns any, and each assertion below checks the field it reads.
    const probe = JSON.parse(probeLine.slice("probe ".length)) as Record<string, unknown>;
    assert.equal(probe.tourFinished, true);
    assert.deepEqual(probe.pageErrors, ["TypeError: parts is not iterable"]);
    assert.deepEqual(probe.missing, ["focusPart"]);
    assert.equal(probe.focusFindsAPart, false);
    assert.equal(probe.rotateTurns, true);
    assert.equal(probe.questionMarkAfterReveal, false);
  });
});
