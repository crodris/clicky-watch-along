// A stand-in for a /live-scene reply whose page never ends its tour, for the "A tour that never ends" recipe in
// features/live-scene.md. A generated page can hang this way with no error: its tour loop never reaches the line
// that posts tourFinished. It listens on 127.0.0.1:<listenPort>, answers every POST /live-scene with that page and a
// quiz, and passes every other route through to the Worker on 127.0.0.1:<upstreamPort>, streams included, so /chat and
// /tts still answer. Each request prints one line with the time in milliseconds.
//
// Usage: node .claude/skills/verify-clicky/stuck-tour-scene-stub.mjs <listenPort> <upstreamPort>

import http from "node:http";

const [listenPort, upstreamPort] = process.argv.slice(2).map(Number);
if (!Number.isInteger(listenPort) || !Number.isInteger(upstreamPort)) {
  console.error("usage: node stuck-tour-scene-stub.mjs <listenPort> <upstreamPort>");
  process.exit(1);
}

// Two labeled parts and the window.liveScene calls the app makes, with a tour that never finishes.
// endTour does finish it, as rule 7 of the /live-scene prompt asks, so a caller that ends the tour sees it end.
const pageThatNeverEndsItsTour = `<!doctype html>
<html><head><meta charset="utf-8"><style>
  body { margin: 0; background: #0b0d12; color: white; font-family: -apple-system, sans-serif; }
  .scene-label { position: absolute; padding: 4px 8px; }
</style></head><body>
<div class="scene-label" style="left: 40%; top: 40%">Left part</div>
<div class="scene-label" style="left: 55%; top: 55%">Right part</div>
<script>
  let tourFinished = false;
  const finishTour = () => {
    if (tourFinished) return;
    tourFinished = true;
    window.__tourFinished = true;
    window.webkit?.messageHandlers?.liveSceneEvent?.postMessage("tourFinished");
  };
  window.liveScene = {
    reveal() {},
    zoomBy() {},
    focusPart() {},
    rotateBy() {},
    endTour: finishTour,
    getState: () => ({ yawDegrees: 0, pitchDegrees: 0, zoom: 0, focusedLabel: "", tourFinished }),
  };
  window.__ready = true;
</script>
</body></html>`;

const sceneReply = JSON.stringify({
  html: pageThatNeverEndsItsTour,
  quiz: { answerLabel: "Left part", question: "What is this part?", functionWords: [], explanation: "It is the left part." },
});

const server = http.createServer((request, response) => {
  const requestPath = request.url ?? "/";
  if (request.method === "POST" && requestPath.startsWith("/live-scene")) {
    console.log(`${Date.now()} answered ${request.method} ${requestPath} with a page that never ends its tour`);
    request.resume();
    response.writeHead(200, { "content-type": "application/json" }).end(sceneReply);
    return;
  }
  console.log(`${Date.now()} passed ${request.method} ${requestPath}`);
  const upstreamRequest = http.request(
    { host: "127.0.0.1", port: upstreamPort, method: request.method, path: requestPath, headers: request.headers },
    (upstreamResponse) => {
      response.writeHead(upstreamResponse.statusCode ?? 502, upstreamResponse.headers);
      upstreamResponse.pipe(response);
    },
  );
  upstreamRequest.on("error", (error) => {
    console.log(`${Date.now()} upstream failed for ${requestPath}: ${error.message}`);
    // A failure after the headers went out can only cut the reply off, since writeHead would throw.
    if (response.headersSent) response.destroy();
    else response.writeHead(502).end();
  });
  request.pipe(upstreamRequest);
});

server.listen(listenPort, "127.0.0.1", () => {
  console.log(`${Date.now()} listening on 127.0.0.1:${listenPort}, passing to 127.0.0.1:${upstreamPort}, stubbing /live-scene`);
});
