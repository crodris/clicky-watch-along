import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import { pageWithLocalThree, sceneShotsChromeProcesses, sceneShotsFolderIsStale, scenePageContentSecurityPolicy } from "./sceneShots.ts";

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
      `83128 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new --remote-debugging-port=0 ${profile} --window-size=1280,800`,
      `83177 /Applications/Google Chrome.app/Contents/Frameworks/Helpers/Google Chrome Helper --type=gpu-process --headless ${profile}`,
      // A Chrome with a window, even one pointed at a scene-shots folder by hand, is not a leftover of the judge.
      `90003 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome ${profile}`,
      // Chris's own Chrome has a window, so it has no --headless flag.
      "35023 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      // Other headless Chromes, such as the judge's screenshot runs and Remotion's, keep their own profiles.
      "90001 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new --user-data-dir=/Users/c/bench/out/chrome-profile",
      // A scene-shots path outside the profile flag, such as in an argument to another program, is not a Chrome profile.
      "90002 grep --headless scene-shots-9XaGV9",
    ].join("\n");

    assert.deepEqual(sceneShotsChromeProcesses(psOutput), [
      { pid: 83128, scratchDirectory: "/var/folders/ab/T/scene-shots-9XaGV9" },
      { pid: 83177, scratchDirectory: "/var/folders/ab/T/scene-shots-9XaGV9" },
    ]);
  });
});

describe("sceneShotsFolderIsStale", () => {
  const alive = (pid: number) => pid === 100;

  it("is stale only when the owner process is gone", () => {
    assert.equal(sceneShotsFolderIsStale("100", 10 * 60_000, alive), false);
    assert.equal(sceneShotsFolderIsStale("200", 1_000, alive), true);
  });

  it("gives a folder with no usable owner file a minute before calling it stale", () => {
    assert.equal(sceneShotsFolderIsStale(undefined, 1_000, alive), false);
    assert.equal(sceneShotsFolderIsStale(undefined, 61_000, alive), true);
    assert.equal(sceneShotsFolderIsStale("not a pid", 61_000, alive), true);
  });
});

/**
 * Runs fixtures/open-scene-camera.ts with fixtures/fake-chrome.ts as Chrome, in a temporary folder of its own, and
 * waits until it has opened the camera. The fake Chrome is a node process, so its flags show in `ps` like Chrome's.
 */
// A process that ignores its signal would hang a test forever, so each test has a timeout that fails it instead.
describe("SceneCamera ends its Chrome", { timeout: 30_000 }, () => {
  let sandbox = "";
  // Every process a test starts, so a failed assertion leaves nothing running to hold the test run open.
  const startedProcessIds = new Set<number>();
  before(() => {
    sandbox = mkdtempSync(join(tmpdir(), "scene-camera-test-"));
  });
  after(() => {
    for (const processId of startedProcessIds) {
      try {
        process.kill(processId, "SIGKILL");
      } catch {
        // It already ended.
      }
    }
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

  async function openCamera(name: string, argument: "wait" | "throw") {
    const pidFile = join(sandbox, `${name}.pid`);
    const fakeChromeLauncher = join(sandbox, `${name}-chrome`);
    // CHROME_PATH is one executable, so a small script starts the fake Chrome with the flags SceneCamera gives it.
    writeFileSync(fakeChromeLauncher, `#!/bin/sh\nexec node ${join(import.meta.dirname, "fixtures", "fake-chrome.ts")} "$@"\n`);
    chmodSync(fakeChromeLauncher, 0o755);
    const driver: ChildProcess = spawn("node", [join(import.meta.dirname, "fixtures", "open-scene-camera.ts"), argument], {
      env: { ...process.env, TMPDIR: sandbox, CHROME_PATH: fakeChromeLauncher, FAKE_CHROME_PID_FILE: pidFile },
      // The throw case prints its stack trace to stderr, which the test run does not need to show.
      stdio: ["ignore", "pipe", "ignore"],
    });
    if (driver.pid !== undefined) {
      startedProcessIds.add(driver.pid);
    }
    const exited = new Promise<void>((resolve) => driver.once("exit", () => resolve()));
    await new Promise<void>((resolve, reject) => {
      driver.stdout?.on("data", (chunk) => String(chunk).includes("opened") && resolve());
      driver.once("exit", () => reject(new Error("the driver ended before it opened the camera")));
    }).catch((error) => {
      if (argument !== "throw") {
        throw error;
      }
    });
    const fakeChromePid = Number(readFileSync(pidFile, "utf8"));
    startedProcessIds.add(fakeChromePid);
    return { driver, exited, fakeChromePid };
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
});
