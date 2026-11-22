import { afterEach, describe, expect, it, vi } from "vitest";
import { handleRoomFloor } from "./roomFloor";

const depthServiceURL = "http://127.0.0.1:8801";

const goodRequest = { jpegBase64: "AAAA", maskPngBase64: "BBBB", anchor: { u: 640.5, v: 560 } };

const goodServiceReply = {
  center: [0.1, 1.2, 3.4],
  right: [1, 0, 0],
  up: [0, -0.96593, -0.25882],
  forward: [0, -0.25882, 0.96593],
  focalPx: 1100.5,
  principal: [640, 360],
  distanceMeters: 3.6,
  floorTiltDegrees: 15,
  planeInlierShare: 0.92,
  inferenceSeconds: 3.2,
  seconds: 3.4,
};

function requestWithBody(body: unknown): Request {
  return new Request("https://worker.test/room-floor", { method: "POST", body: JSON.stringify(body) });
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

describe("handleRoomFloor", () => {
  it("answers 400 for a body without an anchor, without calling the service", async () => {
    const fetchMock = stubFetch(async () => new Response("{}"));

    const response = await handleRoomFloor(requestWithBody({ jpegBase64: "AAAA" }), depthServiceURL);

    expect(response.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("answers 503 and calls nothing when the depth service URL is not set", async () => {
    const fetchMock = stubFetch(async () => new Response("{}"));

    for (const unsetURL of [undefined, ""]) {
      const response = await handleRoomFloor(requestWithBody(goodRequest), unsetURL);

      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({ error: "The depth service isn't configured" });
    }
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("forwards the body to the service's /floor, not /wall, with POST, a JSON content type, no Origin, and a 60 second timeout", async () => {
    const fetchMock = stubServiceReply(new Response(JSON.stringify(goodServiceReply)));
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    const timeoutSpy = vi.spyOn(AbortSignal, "timeout");
    const requestWithAnOrigin = new Request("https://worker.test/room-floor", {
      method: "POST",
      headers: { origin: "https://shop.example", "content-type": "text/plain" },
      body: JSON.stringify(goodRequest),
    });

    await handleRoomFloor(requestWithAnOrigin, `${depthServiceURL}/`);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [calledURL, init] = fetchMock.mock.calls[0];
    expect(calledURL).toBe(`${depthServiceURL}/floor`);
    expect(init.method).toBe("POST");
    expect(JSON.parse(String(init.body))).toEqual(goodRequest);
    expect(timeoutSpy).toHaveBeenCalledWith(60_000);
    const forwardedHeaders = new Headers(init.headers);
    expect(forwardedHeaders.get("content-type")).toBe("application/json");
    expect(forwardedHeaders.has("origin")).toBe(false);
  });

  it("returns the service's reply unchanged, extra fields included, and logs one line", async () => {
    const serviceReplyWithExtras = { ...goodServiceReply, anExtraField: true };
    stubServiceReply(new Response(JSON.stringify(serviceReplyWithExtras)));
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    const response = await handleRoomFloor(requestWithBody(goodRequest), depthServiceURL);

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(serviceReplyWithExtras);
    expect(logSpy).toHaveBeenCalledTimes(1);
    expect(String(logSpy.mock.calls[0][0])).toMatch(/^\[\/room-floor\] distance 3\.6 m, tilt 15 deg, depth 3\.2 s, total \d+\.\d s$/);
  });

  it("accepts the reply recorded from a live Depth Pro run on 2026-11-21, which the plausibility checks pass", async () => {
    // The depth service's real answer for a frame of a person standing in a room, anchor (1000, 930).
    const recordedReply = {
      center: [0.2559, 0.4113, 1.198],
      right: [0.99762, 0.06617, -0.0194],
      up: [0.06896, -0.95732, 0.28069],
      forward: [0.0, 0.28136, 0.9596],
      focalPx: 1310.69,
      principal: [720.0, 480.0],
      distanceMeters: 1.292,
      floorTiltDegrees: 16.8,
      planeInlierShare: 0.467,
      inferenceSeconds: 12.86,
      seconds: 12.93,
    };
    stubServiceReply(new Response(JSON.stringify(recordedReply)));
    vi.spyOn(console, "log").mockImplementation(() => undefined);

    const response = await handleRoomFloor(requestWithBody(goodRequest), depthServiceURL);

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(recordedReply);
  });

  const badServiceReplies: [string, unknown][] = [
    ["a missing forward vector", { ...goodServiceReply, forward: undefined }],
    ["a missing tilt", { ...goodServiceReply, floorTiltDegrees: undefined }],
    ["a wall's reply, with a wall angle and no forward", { ...goodServiceReply, forward: undefined, floorTiltDegrees: undefined, wallAngleDegrees: 6 }],
    ["a vector with 2 numbers", { ...goodServiceReply, up: [0, -1] }],
    ["a focal length of 0", { ...goodServiceReply, focalPx: 0 }],
    ["a distance of 0", { ...goodServiceReply, distanceMeters: 0 }],
    ["a negative tilt", { ...goodServiceReply, floorTiltDegrees: -1 }],
    ["an inlier share over 1", { ...goodServiceReply, planeInlierShare: 1.2 }],
    ["a text number", { ...goodServiceReply, seconds: "3" }],
  ];

  it.each(badServiceReplies)("answers 502 for a service reply with %s", async (_name, serviceReply) => {
    stubServiceReply(new Response(JSON.stringify(serviceReply)));

    const response = await handleRoomFloor(requestWithBody(goodRequest), depthServiceURL);

    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: expect.stringContaining("not what the Worker expects") });
  });

  it("answers 502 for a service reply that is not JSON", async () => {
    stubServiceReply(new Response("<html>oops</html>"));

    const response = await handleRoomFloor(requestWithBody(goodRequest), depthServiceURL);

    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "The depth service's reply was not JSON" });
  });

  it("answers 502 with the service's error text on one line when the service answers non-200", async () => {
    stubServiceReply(new Response(JSON.stringify({ error: "ValueError: boom\nagain" }), { status: 500 }));

    const response = await handleRoomFloor(requestWithBody(goodRequest), depthServiceURL);

    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "The depth service answered 500: ValueError: boom again" });
  });

  it("passes the service's 422 through as 422 with its error, since the service found no floor to measure", async () => {
    stubServiceReply(new Response(JSON.stringify({ error: "Too little bare floor around that point" }), { status: 422 }));

    const response = await handleRoomFloor(requestWithBody(goodRequest), depthServiceURL);

    expect(response.status).toBe(422);
    expect(await response.json()).toEqual({ error: "Too little bare floor around that point" });
  });

  const implausibleFloors: [string, Partial<typeof goodServiceReply>, string][] = [
    ["nearer than 0.3 m", { distanceMeters: 0.29 }, "0.29 m away"],
    ["farther than 12 m", { distanceMeters: 12.5 }, "12.5 m away"],
    ["tilted over 30 degrees", { floorTiltDegrees: 30.5 }, "30.5 degrees"],
    ["under 30 percent on one plane", { planeInlierShare: 0.29 }, "29 percent"],
  ];

  it.each(implausibleFloors)("answers 422 for a floor %s", async (_name, replyChange, errorFragment) => {
    stubServiceReply(new Response(JSON.stringify({ ...goodServiceReply, ...replyChange })));

    const response = await handleRoomFloor(requestWithBody(goodRequest), depthServiceURL);

    expect(response.status).toBe(422);
    expect(await response.json()).toEqual({ error: expect.stringContaining(errorFragment) });
  });

  it("accepts a floor exactly at 0.3 m, 12 m, 30 degrees, and 30 percent on one plane", async () => {
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    for (const replyChange of [{ distanceMeters: 0.3 }, { distanceMeters: 12 }, { floorTiltDegrees: 30 }, { planeInlierShare: 0.3 }]) {
      stubServiceReply(new Response(JSON.stringify({ ...goodServiceReply, ...replyChange })));

      const response = await handleRoomFloor(requestWithBody(goodRequest), depthServiceURL);

      expect(response.status).toBe(200);
    }
  });

  it("answers 502 when the service cannot be reached or times out", async () => {
    for (const failure of [new TypeError("fetch failed"), new DOMException("The operation timed out", "TimeoutError")]) {
      stubFetch(async () => {
        throw failure;
      });

      const response = await handleRoomFloor(requestWithBody(goodRequest), depthServiceURL);

      expect(response.status).toBe(502);
      expect(await response.json()).toEqual({ error: "The depth service could not be reached" });
    }
  });
});
