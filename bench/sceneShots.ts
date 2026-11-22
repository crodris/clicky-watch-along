// Screenshots of a generated /live-scene page for judge.ts. The page loads in headless Chrome as the app shows it, with
// three.js served from the app's bundle, and two moments go side by side into one PNG: the view when the camera tour
// ends, and the view after the page does something, a run for a simulation and a half turn for a 3D model.
//
// Chrome is driven over the DevTools protocol, since the command line can take one screenshot only and cannot wait for
// the tour to end. A small local server serves the page and three.js, because Chrome refuses a module script from file://.

import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

/**
 * The policy the app serves a generated page with (LiveSceneOverlay.livePageContentSecurityPolicy), with this server's
 * own origin in place of clicky-asset:, so a page can load three.js and the screenshots but cannot fetch from or post to
 * any other host, such as a local Worker that holds API keys. The app's WebKit view enforces `webrtc 'block'`, and
 * headless Chrome may ignore it, so a page here may still open a WebRTC connection. Unlike the app, the bench also does not
 * block a page that navigates itself away, which can send a GET.
 */
export const scenePageContentSecurityPolicy =
  "default-src 'none'; script-src 'unsafe-inline' 'self'; style-src 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; base-uri 'none'; form-action 'none'; webrtc 'block'";

/** The app serves three.js at clicky-asset://three/, and the scene prompt's import map points there. */
const appThreeURLPrefix = "clicky-asset://three/";

/** The page with its three.js imports pointed at the local server's /three/ path. */
export function pageWithLocalThree(html: string): string {
  return html.replaceAll(appThreeURLPrefix, "/three/");
}

export type SceneKind = "model" | "simulation";

export type SceneShotOutcome = {
  /** False when the page never set __tourFinished, so the first shot was taken after endTour or the wait ran out. */
  tourFinished: boolean;
  /** What the second shot shows, for the description the judge reads. */
  secondShot: "after a run" | "the run did not finish in 20 seconds" | "the page has no run()" | "after a half turn" | "the page has no rotateBy()";
  /** Errors the page threw, which the judge reads as a broken page. */
  pageErrors: string[];
};

const scratchDirectoryPrefix = "scene-shots-";
const ownerPidFileName = "owner-pid";
/** A folder with no owner file is left alone this long, since a run writes the file right after it makes the folder. */
const unclaimedFolderGraceMs = 60_000;

type SceneShotsChromeProcess = { pid: number; parentPid: number; scratchDirectory: string };

/**
 * The headless Chrome processes in `ps -axo pid=,ppid=,command=` output that run on a scene-shots scratch folder's
 * profile, with that folder. Helper processes carry the same flags, so one Chrome shows up several times, and killing
 * every pid is harmless. A Chrome with a window, such as Chris's own, has no --headless flag and never matches.
 */
export function sceneShotsChromeProcesses(psOutput: string): SceneShotsChromeProcess[] {
  return psOutput.split("\n").flatMap((line) => {
    const match = /^\s*(\d+)\s+(\d+)\s.*--headless.*--user-data-dir=(\S*\/scene-shots-[^/\s]+)\/chrome-profile/.exec(line);
    return match === null ? [] : [{ pid: Number(match[1]), parentPid: Number(match[2]), scratchDirectory: match[3] }];
  });
}

/** launchd's pid. A process whose parent died is handed to it, so a Chrome with this parent has no run waiting for it. */
const launchdPid = 1;

function processIsAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM means the process exists and belongs to someone else.
    return error instanceof Error && "code" in error && error.code === "EPERM";
  }
}

/**
 * True when no live run owns the folder. A folder with an owner file is stale when that process is gone. A run from
 * before the owner file existed leaves none, so such a folder is stale only when it is not brand new and no Chrome on
 * it has a live parent, since another checkout on older code may still be running its judge between shots.
 */
export function sceneShotsFolderIsStale(
  ownerPidText: string | undefined,
  folderAgeMs: number,
  ownerIsAlive: (pid: number) => boolean,
  aChromeOnItHasALiveParent: boolean,
): boolean {
  const ownerPid = Number(ownerPidText?.trim());
  if (ownerPidText === undefined || !Number.isInteger(ownerPid) || ownerPid <= 0) {
    return folderAgeMs > unclaimedFolderGraceMs && !aChromeOnItHasALiveParent;
  }
  return !ownerIsAlive(ownerPid);
}

/**
 * Kills the headless Chrome and deletes the scratch folder that an earlier run left behind when it was killed
 * with SIGKILL, which no handler can catch. A Chrome like that has launchd as its parent, answers Apple Events
 * sent to "Google Chrome" in place of the real Chrome, and fails them with "Executing JavaScript through AppleScript
 * is turned off". A folder that a live run still owns is left alone, so two judge runs can overlap. A folder that
 * another process removes or locks while this runs is skipped, since the run that called this still has to open.
 */
export function removeStaleSceneShots() {
  const scratchFolders = readdirSync(tmpdir())
    .filter((name) => name.startsWith(scratchDirectoryPrefix))
    .map((name) => join(tmpdir(), name));
  if (scratchFolders.length === 0) {
    return;
  }
  const chromeProcesses = sceneShotsChromeProcesses(execFileSync("ps", ["-axo", "pid=,ppid=,command="], { encoding: "utf8" }));
  for (const folder of scratchFolders) {
    try {
      const ownerPidPath = join(folder, ownerPidFileName);
      const ownerPidText = existsSync(ownerPidPath) ? readFileSync(ownerPidPath, "utf8") : undefined;
      const chromesOnFolder = chromeProcesses.filter((chromeProcess) => chromeProcess.scratchDirectory === folder);
      const aChromeOnItHasALiveParent = chromesOnFolder.some((chromeProcess) => chromeProcess.parentPid !== launchdPid);
      if (!sceneShotsFolderIsStale(ownerPidText, Date.now() - statSync(folder).mtimeMs, processIsAlive, aChromeOnItHasALiveParent)) {
        continue;
      }
      for (const { pid } of chromesOnFolder) {
        try {
          process.kill(pid, "SIGKILL");
        } catch {
          // It exited on its own since ps ran.
        }
      }
      rmSync(folder, { recursive: true, force: true });
    } catch {
      // Another run removed the folder first, or it belongs to another user. Leave it.
    }
  }
}

const viewport = { width: 1280, height: 800 };
const tourWaitMs = 20_000;
const runWaitMs = 20_000;

type ProtocolReply = { id?: number; result?: Record<string, unknown>; error?: { message: string }; method?: string; params?: Record<string, unknown> };

/** One DevTools protocol connection to one page target. */
class PageConnection {
  private nextMessageId = 1;
  private readonly pending = new Map<number, (reply: ProtocolReply) => void>();
  readonly pageErrors: string[] = [];
  private readonly socket: WebSocket;

  private constructor(socket: WebSocket) {
    this.socket = socket;
    socket.addEventListener("message", (event) => {
      const reply = JSON.parse(String(event.data)) as ProtocolReply;
      if (reply.id !== undefined) {
        this.pending.get(reply.id)?.(reply);
        this.pending.delete(reply.id);
      } else if (reply.method === "Runtime.exceptionThrown") {
        const details = reply.params?.exceptionDetails as { exception?: { description?: string }; text?: string } | undefined;
        this.pageErrors.push((details?.exception?.description ?? details?.text ?? "an error").split("\n")[0]);
      }
    });
  }

  static async open(webSocketURL: string): Promise<PageConnection> {
    const socket = new WebSocket(webSocketURL);
    await new Promise((resolve, reject) => {
      socket.addEventListener("open", resolve, { once: true });
      socket.addEventListener("error", reject, { once: true });
    });
    return new PageConnection(socket);
  }

  send(method: string, params: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    const messageId = this.nextMessageId;
    this.nextMessageId += 1;
    return new Promise((resolve, reject) => {
      this.pending.set(messageId, (reply) => (reply.error === undefined ? resolve(reply.result ?? {}) : reject(new Error(`${method}: ${reply.error.message}`))));
      this.socket.send(JSON.stringify({ id: messageId, method, params }));
    });
  }

  /** The value of an expression in the page, or undefined when it threw. A promise is awaited. */
  async evaluate(expression: string): Promise<unknown> {
    const result = await this.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    return (result.result as { value?: unknown } | undefined)?.value;
  }

  async screenshot(format: "jpeg" | "png"): Promise<Buffer> {
    const result = await this.send("Page.captureScreenshot", { format, ...(format === "jpeg" ? { quality: 85 } : {}) });
    return Buffer.from(String(result.data), "base64");
  }

  close() {
    this.socket.close();
  }
}

async function waitFor(check: () => Promise<boolean>, timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await check()) {
      return true;
    }
    await sleep(250);
  }
  return false;
}

function compositePage(firstShotPath: string, secondShotPath: string, firstCaption: string, secondCaption: string): string {
  const figure = (path: string, caption: string) =>
    `<figure><img src="/shots/${basename(path)}"><figcaption>${caption}</figcaption></figure>`;
  return `<!doctype html><html><head><meta charset="utf-8"><style>
    html, body { margin: 0; background: #111; color: #eee; font: 600 18px/1.2 -apple-system, Helvetica, Arial, sans-serif; }
    body { display: flex; gap: 8px; padding: 8px; }
    figure { margin: 0; width: 788px; } img { width: 788px; height: 492px; display: block; border-radius: 4px; }
    figcaption { padding: 8px 2px 0; }
  </style></head><body>${figure(firstShotPath, firstCaption)}${figure(secondShotPath, secondCaption)}</body></html>`;
}

/**
 * Chrome is a child process, so it outlives a node process that ends without closing the camera. Left running, a
 * headless Chrome takes the Apple Events that Clicky's checks send to "Google Chrome" (see removeStaleSceneShots).
 * This kills it, and deletes its scratch folder, when this process exits for any reason it can see: a normal exit,
 * an uncaught error, process.exit, or SIGINT, SIGTERM, or SIGHUP, which have no default exit once a handler exists,
 * so the handler exits with the shell's 128 plus the signal number. SIGKILL cannot be caught, so the next
 * SceneCamera.open cleans up after it. Returns a function that removes the handlers.
 */
function killChromeWhenThisProcessEnds(chrome: ChildProcess, scratchDirectory: string): () => void {
  const killChromeAndForgetItsFolder = () => {
    chrome.kill("SIGKILL");
    // Chrome's helper processes can still be writing to the profile for a moment after the main process dies.
    rmSync(scratchDirectory, { recursive: true, force: true, maxRetries: 5 });
  };
  const exitSignals = [
    ["SIGINT", 2],
    ["SIGTERM", 15],
    ["SIGHUP", 1],
  ] as const;
  const signalHandlers = exitSignals.map(([signalName, signalNumber]) => {
    const handler = () => process.exit(128 + signalNumber);
    process.once(signalName, handler);
    return [signalName, handler] as const;
  });
  process.once("exit", killChromeAndForgetItsFolder);
  return () => {
    process.off("exit", killChromeAndForgetItsFolder);
    for (const [signalName, handler] of signalHandlers) {
      process.off(signalName, handler);
    }
  };
}

/** Headless Chrome and the local server, opened once for every page a judge run draws. */
type SceneCameraParts = {
  chrome: ChildProcess;
  server: Server;
  serverOrigin: string;
  devToolsOrigin: string;
  scratchDirectory: string;
  pagesByPath: Map<string, string>;
  stopWatchingForExit: () => void;
};

export class SceneCamera {
  private readonly chrome: ChildProcess;
  private readonly server: Server;
  private readonly serverOrigin: string;
  private readonly devToolsOrigin: string;
  private readonly scratchDirectory: string;
  private readonly pagesByPath: Map<string, string>;
  private readonly stopWatchingForExit: () => void;

  private constructor(parts: SceneCameraParts) {
    this.chrome = parts.chrome;
    this.server = parts.server;
    this.serverOrigin = parts.serverOrigin;
    this.devToolsOrigin = parts.devToolsOrigin;
    this.scratchDirectory = parts.scratchDirectory;
    this.pagesByPath = parts.pagesByPath;
    this.stopWatchingForExit = parts.stopWatchingForExit;
  }

  static async open(threeAssetsDirectory: string): Promise<SceneCamera> {
    removeStaleSceneShots();
    const scratchDirectory = mkdtempSync(join(tmpdir(), scratchDirectoryPrefix));
    writeFileSync(join(scratchDirectory, ownerPidFileName), String(process.pid));
    const pagesByPath = new Map<string, string>();
    const server = createServer((request, response) => {
      const path = new URL(request.url ?? "/", "http://localhost").pathname;
      const threeFile = path.startsWith("/three/") ? basename(path) : undefined;
      if (threeFile !== undefined && threeFile.endsWith(".js") && existsSync(join(threeAssetsDirectory, threeFile))) {
        response.writeHead(200, { "content-type": "text/javascript" }).end(readFileSync(join(threeAssetsDirectory, threeFile)));
      } else if (path.startsWith("/shots/") && existsSync(join(scratchDirectory, basename(path)))) {
        response.writeHead(200, { "content-type": "image/jpeg" }).end(readFileSync(join(scratchDirectory, basename(path))));
      } else if (pagesByPath.has(path)) {
        response
          .writeHead(200, { "content-type": "text/html; charset=utf-8", "content-security-policy": scenePageContentSecurityPolicy })
          .end(pagesByPath.get(path));
      } else {
        // Any other path on this server, such as a texture the page names, gets a 404. Other hosts are blocked by the policy.
        response.writeHead(404).end();
      }
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (address === null || typeof address === "string") {
      throw new Error("The scene shot server has no port");
    }

    const chromePath = process.env.CHROME_PATH ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
    const profileDirectory = join(scratchDirectory, "chrome-profile");
    const chrome = spawn(
      chromePath,
      [
        "--headless=new",
        "--remote-debugging-port=0",
        `--user-data-dir=${profileDirectory}`,
        `--window-size=${viewport.width},${viewport.height}`,
        "--hide-scrollbars",
        // WebGL in headless Chrome runs on the SwiftShader software renderer.
        "--use-angle=swiftshader",
        "--enable-unsafe-swiftshader",
        "about:blank",
      ],
      { stdio: "ignore" },
    );
    const stopWatchingForExit = killChromeWhenThisProcessEnds(chrome, scratchDirectory);
    const portFilePath = join(profileDirectory, "DevToolsActivePort");
    if (!(await waitFor(async () => existsSync(portFilePath) && readFileSync(portFilePath, "utf8").includes("\n"), 15_000))) {
      stopWatchingForExit();
      chrome.kill("SIGKILL");
      server.close();
      rmSync(scratchDirectory, { recursive: true, force: true });
      throw new Error("Chrome never opened its DevTools port");
    }
    const devToolsPort = readFileSync(portFilePath, "utf8").split("\n")[0];
    return new SceneCamera({
      chrome,
      server,
      serverOrigin: `http://127.0.0.1:${address.port}`,
      devToolsOrigin: `http://127.0.0.1:${devToolsPort}`,
      scratchDirectory,
      pagesByPath,
      stopWatchingForExit,
    });
  }

  /** Draws one page and writes the side-by-side PNG to pngPath. */
  async shoot(html: string, sceneKind: SceneKind, pngPath: string): Promise<SceneShotOutcome> {
    const pageID = `page-${this.pagesByPath.size + 1}`;
    this.pagesByPath.set(`/${pageID}.html`, pageWithLocalThree(html));
    const target = (await (await fetch(`${this.devToolsOrigin}/json/new?about:blank`, { method: "PUT" })).json()) as { id: string; webSocketDebuggerUrl: string };
    const page = await PageConnection.open(target.webSocketDebuggerUrl);
    try {
      await page.send("Runtime.enable");
      await page.send("Page.enable");
      await page.send("Emulation.setDeviceMetricsOverride", { ...viewport, deviceScaleFactor: 1, mobile: false });
      await page.send("Page.navigate", { url: `${this.serverOrigin}/${pageID}.html` });

      const tourFinished = await waitFor(async () => (await page.evaluate("window.__tourFinished === true")) === true, tourWaitMs);
      if (!tourFinished) {
        await page.evaluate("window.liveScene?.endTour?.()");
      }
      await sleep(800);
      const firstShotPath = join(this.scratchDirectory, `${pageID}-1.jpg`);
      writeFileSync(firstShotPath, await page.screenshot("jpeg"));

      let secondShot: SceneShotOutcome["secondShot"];
      if (sceneKind === "simulation") {
        const runOutcome = await page.evaluate(`(async () => {
          if (typeof window.liveScene?.run !== "function") return "missing";
          const finished = await Promise.race([Promise.resolve(window.liveScene.run()).then(() => "done", () => "done"),
            new Promise((resolve) => setTimeout(() => resolve("timeout"), ${runWaitMs}))]);
          return finished;
        })()`);
        secondShot = runOutcome === "missing" ? "the page has no run()" : runOutcome === "timeout" ? "the run did not finish in 20 seconds" : "after a run";
        await sleep(500);
      } else {
        const turned = await page.evaluate("typeof window.liveScene?.rotateBy === 'function' ? (window.liveScene.rotateBy(180, 10), true) : false");
        secondShot = turned === true ? "after a half turn" : "the page has no rotateBy()";
        await sleep(1_200);
      }
      const secondShotPath = join(this.scratchDirectory, `${pageID}-2.jpg`);
      writeFileSync(secondShotPath, await page.screenshot("jpeg"));

      const firstCaption = tourFinished ? "When the camera tour ends" : "The tour never ended, so this is after endTour or 20 seconds";
      this.pagesByPath.set(`/${pageID}-shots.html`, compositePage(firstShotPath, secondShotPath, firstCaption, secondShot[0].toUpperCase() + secondShot.slice(1)));
      await page.send("Emulation.setDeviceMetricsOverride", { width: 1600, height: 540, deviceScaleFactor: 1, mobile: false });
      await page.send("Page.navigate", { url: `${this.serverOrigin}/${pageID}-shots.html` });
      await waitFor(async () => (await page.evaluate("[...document.images].every((image) => image.complete && image.naturalWidth > 0)")) === true, 5_000);
      writeFileSync(pngPath, await page.screenshot("png"));
      return { tourFinished, secondShot, pageErrors: [...new Set(page.pageErrors)].slice(0, 3) };
    } finally {
      page.close();
      await fetch(`${this.devToolsOrigin}/json/close/${target.id}`).catch(() => undefined);
    }
  }

  async close() {
    // Chrome writes to its profile until it exits, so the folder is removed only after that.
    // A Chrome that already exited, such as one that crashed mid-run, never emits "exit" again.
    if (this.chrome.exitCode === null && this.chrome.signalCode === null) {
      const chromeExited = new Promise((resolve) => this.chrome.once("exit", resolve));
      this.chrome.kill();
      await chromeExited;
    }
    this.stopWatchingForExit();
    await new Promise((resolve) => this.server.close(resolve));
    rmSync(this.scratchDirectory, { recursive: true, force: true });
  }
}
