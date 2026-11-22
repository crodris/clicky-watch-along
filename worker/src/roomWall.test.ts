import { afterEach, describe, expect, it, vi } from "vitest";
import { handleRoomWall } from "./roomWall";

const depthServiceURL = "http://127.0.0.1:8801";

const goodRequest = { jpegBase64: "AAAA", maskPngBase64: "BBBB", anchor: { u: 640.5, v: 360 } };

const goodServiceReply = {
  center: [0.1, -0.2, 2.4],
  right: [1, 0, 0],
  up: [0, -1, 0],
  focalPx: 1100.5,
  principal: [640, 360],
  distanceMeters: 2.41,
  wallAngleDegrees: 6.3,
  planeInlierShare: 0.92,
  inferenceSeconds: 3.2,
  seconds: 3.4,
};

function requestWithBody(body: unknown): Request {
  return new Request("https://worker.test/room-wall", { method: "POST", body: JSON.stringify(body) });
}

function stubFetch(handler: (url: string, init: RequestInit) => Promise<Response>) {
  const fetchMock = vi.fn(handler);
  vi.stubGlobal("fetch", fetchMock);
  vi.spyOn(console, "error").mockImplementation(() => undefined);
  return fetchMock;
}

function stubServiceReply(serviceReply: Response) {
  return stubFetch(async () => serviceReply);
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("handleRoomWall request limits", () => {
  const badRequests: [string, unknown][] = [
    ["no photo", { anchor: goodRequest.anchor }],
    ["an empty photo", { ...goodRequest, jpegBase64: "" }],
    ["a photo over 4 MB of base64", { ...goodRequest, jpegBase64: "a".repeat(4_000_001) }],
    ["a mask over 1 MB of base64", { ...goodRequest, maskPngBase64: "a".repeat(1_000_001) }],
    ["no anchor", { jpegBase64: "AAAA" }],
    ["an anchor with a text coordinate", { ...goodRequest, anchor: { u: "1", v: 2 } }],
    ["an anchor with a missing coordinate", { ...goodRequest, anchor: { u: 1 } }],
  ];

  it.each(badRequests)("answers 400 for %s without calling the service", async (_name, body) => {
    const fetchMock = stubFetch(async () => new Response("{}"));

    const response = await handleRoomWall(requestWithBody(body), depthServiceURL);

    expect(response.status).toBe(400);
    expect(await response.json()).toHaveProperty("error");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("accepts a photo and a mask exactly at the limits, and no mask", async () => {
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    stubServiceReply(new Response(JSON.stringify(goodServiceReply)));
    const atTheLimits = await handleRoomWall(
      requestWithBody({ ...goodRequest, jpegBase64: "a".repeat(4_000_000), maskPngBase64: "b".repeat(1_000_000) }),
      depthServiceURL,
    );
    stubServiceReply(new Response(JSON.stringify(goodServiceReply)));
    const withNoMask = await handleRoomWall(requestWithBody({ jpegBase64: "AAAA", anchor: goodRequest.anchor }), depthServiceURL);

    expect(atTheLimits.status).toBe(200);
    expect(withNoMask.status).toBe(200);
  });
});

describe("handleRoomWall", () => {
  it("answers 503 and calls nothing when the depth service URL is not set", async () => {
    const fetchMock = stubFetch(async () => new Response("{}"));

    for (const unsetURL of [undefined, ""]) {
      const response = await handleRoomWall(requestWithBody(goodRequest), unsetURL);

      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({ error: "The depth service isn't configured" });
    }
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("forwards the body to the service's /wall with POST and a 60 second timeout", async () => {
    const fetchMock = stubServiceReply(new Response(JSON.stringify(goodServiceReply)));
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    const timeoutSpy = vi.spyOn(AbortSignal, "timeout");

    await handleRoomWall(requestWithBody(goodRequest), `${depthServiceURL}/`);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [calledURL, init] = fetchMock.mock.calls[0];
    expect(calledURL).toBe(`${depthServiceURL}/wall`);
    expect(init.method).toBe("POST");
    expect(JSON.parse(String(init.body))).toEqual(goodRequest);
    expect(timeoutSpy).toHaveBeenCalledWith(60_000);
    expect(init.signal).toBeInstanceOf(AbortSignal);
  });

  it("sends the service a JSON body and no Origin header, which the service refuses", async () => {
    const fetchMock = stubServiceReply(new Response(JSON.stringify(goodServiceReply)));
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    // The app's request carries an Origin header here, which must not reach the service.
    const requestWithAnOrigin = new Request("https://worker.test/room-wall", {
      method: "POST",
      headers: { origin: "https://shop.example", "content-type": "text/plain" },
      body: JSON.stringify(goodRequest),
    });

    await handleRoomWall(requestWithAnOrigin, depthServiceURL);

    const [, init] = fetchMock.mock.calls[0];
    const forwardedHeaders = new Headers(init.headers);
    expect(forwardedHeaders.get("content-type")).toBe("application/json");
    expect(forwardedHeaders.has("origin")).toBe(false);
  });

  it("returns the service's reply unchanged, extra fields included, and logs one line", async () => {
    const serviceReplyWithExtras = { ...goodServiceReply, focalWasGiven: false };
    stubServiceReply(new Response(JSON.stringify(serviceReplyWithExtras)));
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    const response = await handleRoomWall(requestWithBody(goodRequest), depthServiceURL);

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(serviceReplyWithExtras);
    expect(logSpy).toHaveBeenCalledTimes(1);
    expect(String(logSpy.mock.calls[0][0])).toMatch(/^\[\/room-wall\] distance 2\.41 m, angle 6\.3 deg, depth 3\.2 s, total \d+\.\d s$/);
  });

  const badServiceReplies: [string, unknown][] = [
    ["a missing field", { ...goodServiceReply, center: undefined }],
    ["a vector with 2 numbers", { ...goodServiceReply, right: [1, 0] }],
    ["a focal length of 0", { ...goodServiceReply, focalPx: 0 }],
    ["a distance of 0", { ...goodServiceReply, distanceMeters: 0 }],
    ["an inlier share over 1", { ...goodServiceReply, planeInlierShare: 1.2 }],
    ["a text number", { ...goodServiceReply, seconds: "3" }],
  ];

  it.each(badServiceReplies)("answers 502 for a service reply with %s", async (_name, serviceReply) => {
    stubServiceReply(new Response(JSON.stringify(serviceReply)));

    const response = await handleRoomWall(requestWithBody(goodRequest), depthServiceURL);

    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: expect.stringContaining("not what the Worker expects") });
  });

  it("answers 502 for a service reply that is not JSON", async () => {
    stubServiceReply(new Response("<html>oops</html>"));

    const response = await handleRoomWall(requestWithBody(goodRequest), depthServiceURL);

    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "The depth service's reply was not JSON" });
  });

  it("answers 502 with the service's error text on one line when the service answers non-200", async () => {
    stubServiceReply(new Response(JSON.stringify({ error: "ValueError: Too little bare wall\naround that point" }), { status: 500 }));

    const response = await handleRoomWall(requestWithBody(goodRequest), depthServiceURL);

    expect(response.status).toBe(502);
    const { error } = (await response.json()) as { error: string };
    expect(error).toBe("The depth service answered 500: ValueError: Too little bare wall around that point");
    expect(error).not.toContain("\n");
  });

  it("passes the service's 422 through as 422 with its error, since the service found no wall to measure", async () => {
    stubServiceReply(new Response(JSON.stringify({ error: "Too little bare wall around that point" }), { status: 422 }));

    const response = await handleRoomWall(requestWithBody(goodRequest), depthServiceURL);

    expect(response.status).toBe(422);
    expect(await response.json()).toEqual({ error: "Too little bare wall around that point" });
  });

  const implausibleWalls: [string, Partial<typeof goodServiceReply>, string][] = [
    ["nearer than 0.3 m", { distanceMeters: 0.29 }, "0.29 m away"],
    ["farther than 12 m", { distanceMeters: 12.5 }, "12.5 m away"],
    ["under 30 percent on one plane", { planeInlierShare: 0.29 }, "29 percent"],
  ];

  it.each(implausibleWalls)("answers 422 for a wall %s", async (_name, replyChange, errorFragment) => {
    stubServiceReply(new Response(JSON.stringify({ ...goodServiceReply, ...replyChange })));

    const response = await handleRoomWall(requestWithBody(goodRequest), depthServiceURL);

    expect(response.status).toBe(422);
    expect(await response.json()).toEqual({ error: expect.stringContaining(errorFragment) });
  });

  it("accepts a wall exactly at 0.3 m, 12 m, and 30 percent on one plane", async () => {
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    for (const replyChange of [{ distanceMeters: 0.3 }, { distanceMeters: 12 }, { planeInlierShare: 0.3 }]) {
      stubServiceReply(new Response(JSON.stringify({ ...goodServiceReply, ...replyChange })));

      const response = await handleRoomWall(requestWithBody(goodRequest), depthServiceURL);

      expect(response.status).toBe(200);
    }
  });

  it("answers 502 with the service's plain text when its error is not JSON", async () => {
    stubServiceReply(new Response("Bad   gateway\n", { status: 502 }));

    const response = await handleRoomWall(requestWithBody(goodRequest), depthServiceURL);

    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "The depth service answered 502: Bad gateway" });
  });

  it("answers 502 when the service cannot be reached or times out", async () => {
    for (const failure of [new TypeError("fetch failed"), new DOMException("The operation timed out", "TimeoutError")]) {
      stubFetch(async () => {
        throw failure;
      });

      const response = await handleRoomWall(requestWithBody(goodRequest), depthServiceURL);

      expect(response.status).toBe(502);
      expect(await response.json()).toEqual({ error: "The depth service could not be reached" });
    }
  });
});
