// A stand-in for a hung Worker, for the "A hung brain" recipe in features/voice-commands.md.
// It listens on 127.0.0.1:<listenPort>, holds every POST /v1/messages open without ever answering, and passes every
// other route through to the Worker on 127.0.0.1:<upstreamPort>, streams included, so the keyword path's /chat and
// /tts still answer. Each request prints one line with the time in milliseconds, so the brain's 8 second turn timeout
// shows as the gap between the held /v1/messages line and the fallback's /chat line.
//
// Usage: node .claude/skills/verify-clicky/hung-messages-stub.mjs <listenPort> <upstreamPort>

import http from "node:http";

const [listenPort, upstreamPort] = process.argv.slice(2).map(Number);
if (!Number.isInteger(listenPort) || !Number.isInteger(upstreamPort)) {
  console.error("usage: node hung-messages-stub.mjs <listenPort> <upstreamPort>");
  process.exit(1);
}

const heldRequests = [];

const server = http.createServer((request, response) => {
  const requestPath = request.url ?? "/";
  if (request.method === "POST" && requestPath.startsWith("/v1/messages")) {
    console.log(`${Date.now()} held ${request.method} ${requestPath}`);
    // Kept so the socket stays open until the harness gives up and closes it.
    heldRequests.push(response);
    request.resume();
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
    response.writeHead(502).end();
  });
  request.pipe(upstreamRequest);
});

server.listen(listenPort, "127.0.0.1", () => {
  console.log(`${Date.now()} listening on 127.0.0.1:${listenPort}, passing to 127.0.0.1:${upstreamPort}, holding /v1/messages`);
});
