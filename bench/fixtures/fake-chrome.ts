// A stand-in for headless Chrome, so sceneShots.test.ts can check how SceneCamera ends its Chrome without a real one.
// It takes the flags SceneCamera passes, writes the DevToolsActivePort file Chrome writes into its profile, records its
// pid in the file FAKE_CHROME_PID_FILE names, and then waits.
//
// With FAKE_CHROME_DEVTOOLS set it also answers the DevTools protocol for one page at a time, so a test can drive
// SceneCamera.shoot and SceneCamera.probe: it evaluates each Runtime.evaluate expression against a small fake scene page
// that has no focusPart, fails the first FAKE_CHROME_CAPTURE_FAILURES screenshot captures, and reports
// FAKE_CHROME_PAGE_ERROR as a page error after each navigation.
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage } from "node:http";
import type { Socket } from "node:net";
import { join } from "node:path";
import { createContext, runInContext } from "node:vm";

const profileFlag = process.argv.find((argument) => argument.startsWith("--user-data-dir="));
if (profileFlag === undefined || process.env.FAKE_CHROME_PID_FILE === undefined) {
  process.exit(3);
}
const profileDirectory = profileFlag.slice("--user-data-dir=".length);
mkdirSync(profileDirectory, { recursive: true });
const pidFile = process.env.FAKE_CHROME_PID_FILE;

if (process.env.FAKE_CHROME_DEVTOOLS === undefined) {
  writeFileSync(join(profileDirectory, "DevToolsActivePort"), "9222\n/devtools/browser/fake\n");
  writeFileSync(pidFile, String(process.pid));
  setInterval(() => undefined, 1_000);
} else {
  let capturesLeftToFail = Number(process.env.FAKE_CHROME_CAPTURE_FAILURES ?? 0);
  const server = createServer((request, response) => {
    const path = new URL(request.url ?? "/", "http://localhost").pathname;
    if (path === "/json/new") {
      const port = (server.address() as { port: number }).port;
      response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ id: "page-1", webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/page-1` }));
    } else {
      response.writeHead(200).end("{}");
    }
  });

  // A fake scene page: a part, a "?" label, every primitive but focusPart, and a camera that turns.
  function fakeScenePage() {
    const labels = [{ textContent: "Wheel" }, { textContent: "?" }];
    let yawDegrees = 0;
    const liveScene = {
      parts: [{ label: "Wheel", isOuterShell: false }],
      reveal() {
        labels[1].textContent = "Pedal";
      },
      zoomBy: () => true,
      rotateBy(yawToAdd: number) {
        yawDegrees += yawToAdd;
        return true;
      },
      endTour: () => true,
      getState: () => ({ yawDegrees }),
    };
    return createContext({ window: { __tourFinished: true, liveScene }, document: { querySelectorAll: () => labels, images: [] }, setTimeout });
  }

  // One WebSocket text frame from the server, which is never masked.
  function textFrame(text: string): Buffer {
    const payload = Buffer.from(text);
    const header =
      payload.length < 126
        ? Buffer.from([0x81, payload.length])
        : payload.length < 65_536
          ? Buffer.concat([Buffer.from([0x81, 126]), Buffer.from([payload.length >> 8, payload.length & 0xff])])
          : Buffer.concat([Buffer.from([0x81, 127]), Buffer.from([0, 0, 0, 0]), Buffer.from([(payload.length >>> 24) & 0xff, (payload.length >> 16) & 0xff, (payload.length >> 8) & 0xff, payload.length & 0xff])]);
    return Buffer.concat([header, payload]);
  }

  server.on("upgrade", (request: IncomingMessage, socket: Socket) => {
    const acceptKey = createHash("sha1").update(`${request.headers["sec-websocket-key"]}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${acceptKey}\r\n\r\n`);
    let page = fakeScenePage();
    const send = (message: unknown) => socket.write(textFrame(JSON.stringify(message)));
    const answer = async (message: { id: number; method: string; params?: { expression?: string } }) => {
      if (message.method === "Page.captureScreenshot") {
        if (capturesLeftToFail > 0) {
          capturesLeftToFail -= 1;
          send({ id: message.id, error: { message: "Unable to capture screenshot" } });
        } else {
          send({ id: message.id, result: { data: Buffer.from("a fake picture").toString("base64") } });
        }
        return;
      }
      if (message.method === "Runtime.evaluate") {
        try {
          const value = await runInContext(message.params?.expression ?? "undefined", page);
          send({ id: message.id, result: { result: { value } } });
        } catch (error) {
          send({ id: message.id, result: { result: {}, exceptionDetails: { text: String(error) } } });
        }
        return;
      }
      send({ id: message.id, result: {} });
      if (message.method === "Page.navigate") {
        page = fakeScenePage();
        if (process.env.FAKE_CHROME_PAGE_ERROR !== undefined) {
          send({ method: "Runtime.exceptionThrown", params: { exceptionDetails: { exception: { description: process.env.FAKE_CHROME_PAGE_ERROR } } } });
        }
      }
    };
    // Client frames are masked, and these messages are small enough to come whole, so each frame is read on its own.
    let buffered = Buffer.alloc(0);
    socket.on("data", (chunk: Buffer) => {
      buffered = Buffer.concat([buffered, chunk]);
      while (buffered.length >= 2) {
        const opcode = buffered[0] & 0x0f;
        let payloadLength = buffered[1] & 0x7f;
        let offset = 2;
        if (payloadLength === 126) {
          if (buffered.length < 4) return;
          payloadLength = buffered.readUInt16BE(2);
          offset = 4;
        } else if (payloadLength === 127) {
          if (buffered.length < 10) return;
          payloadLength = Number(buffered.readBigUInt64BE(2));
          offset = 10;
        }
        if (buffered.length < offset + 4 + payloadLength) return;
        const mask = buffered.subarray(offset, offset + 4);
        const payload = Buffer.from(buffered.subarray(offset + 4, offset + 4 + payloadLength).map((byte, index) => byte ^ mask[index % 4]));
        buffered = buffered.subarray(offset + 4 + payloadLength);
        if (opcode === 0x8) {
          socket.end();
          return;
        }
        if (opcode === 0x1) void answer(JSON.parse(payload.toString("utf8")));
      }
    });
    socket.on("error", () => undefined);
  });

  server.listen(0, "127.0.0.1", () => {
    const port = (server.address() as { port: number }).port;
    writeFileSync(join(profileDirectory, "DevToolsActivePort"), `${port}\n/devtools/browser/fake\n`);
    writeFileSync(pidFile, String(process.pid));
  });
}
