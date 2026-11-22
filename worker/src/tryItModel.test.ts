import { afterEach, describe, expect, it, vi } from "vitest";
import { handleTryItModel, largestModelByteCount } from "./tryItModel";

const falKey = "fal-test-key";
const submitURL = "https://queue.fal.run/fal-ai/trellis-2";
const statusURL = "https://queue.fal.run/fal-ai/trellis-2/requests/request-1/status";
const responseURL = "https://queue.fal.run/fal-ai/trellis-2/requests/request-1";
const cancelURL = "https://queue.fal.run/fal-ai/trellis-2/requests/request-1/cancel";
const modelFileURL = "https://v3.fal.media/files/lion/model.glb";
/** "glTF", then version 2 and a length, as every GLB starts. */
const glbBytes = new Uint8Array([0x67, 0x6c, 0x54, 0x46, 2, 0, 0, 0, 20, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8]);

const goodBody = { productJPEGBase64: "cHJvZHVjdA==", itemTitle: "Field Lounge Chair" };

function requestWithBody(body: unknown): Request {
  return new Request("https://worker.test/try-it-model", { method: "POST", body: JSON.stringify(body) });
}

const fastOptions = { statusPollIntervalMilliseconds: 1, wholeCallTimeoutMilliseconds: 2_000 };

type FakeFal = {
  submit?: () => Response;
  statuses?: unknown[];
  result?: () => Response;
  download?: () => Response;
};

/** Answers each fal URL with what the test set, and the status checks with `statuses` in turn, repeating the last. */
function stubFal(fakeFal: FakeFal = {}) {
  let statusCheckCount = 0;
  const statuses = fakeFal.statuses ?? [{ status: "IN_QUEUE", queue_position: 0 }, { status: "IN_PROGRESS" }, { status: "COMPLETED", metrics: { inference_time: 31.5 } }];
  // Every fetch the route makes passes an init, so the mock's calls always hold one.
  const fetchMock = vi.fn(async (url: string, _init: RequestInit): Promise<Response> => {
    if (url === submitURL) {
      return fakeFal.submit?.() ?? Response.json({ request_id: "request-1", status_url: statusURL, response_url: responseURL, cancel_url: cancelURL });
    }
    if (url === statusURL) {
      const status = statuses[Math.min(statusCheckCount, statuses.length - 1)];
      statusCheckCount += 1;
      return Response.json(status);
    }
    if (url === responseURL) {
      return fakeFal.result?.() ?? Response.json({ model_glb: { url: modelFileURL, content_type: "model/gltf-binary" } });
    }
    if (url === cancelURL) {
      return Response.json({ status: "CANCELLATION_REQUESTED" }, { status: 202 });
    }
    if (url === modelFileURL) {
      return fakeFal.download?.() ?? new Response(glbBytes, { status: 200, headers: { "content-type": "model/gltf-binary" } });
    }
    return new Response("not found", { status: 404 });
  });
  vi.stubGlobal("fetch", fetchMock);
  vi.spyOn(console, "error").mockImplementation(() => undefined);
  vi.spyOn(console, "log").mockImplementation(() => undefined);
  return fetchMock;
}

function calledURLs(fetchMock: ReturnType<typeof stubFal>): string[] {
  return fetchMock.mock.calls.map((call) => call[0]);
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("handleTryItModel", () => {
  it("submits the photo to TRELLIS 2, waits for it, downloads the GLB, and returns its bytes", async () => {
    const fetchMock = stubFal();

    const response = await handleTryItModel(requestWithBody(goodBody), falKey, fastOptions);

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/octet-stream");
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(glbBytes);

    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe(submitURL);
    expect(init.method).toBe("POST");
    expect(new Headers(init.headers).get("authorization")).toBe("Key fal-test-key");
    expect(JSON.parse(String(init.body))).toEqual({ image_url: "data:image/jpeg;base64,cHJvZHVjdA==" });
    expect(calledURLs(fetchMock)).toEqual([submitURL, statusURL, statusURL, statusURL, responseURL, modelFileURL]);
  });

  it("never sends the fal key with the GLB download, and logs a usage line", async () => {
    const fetchMock = stubFal();
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    await handleTryItModel(requestWithBody(goodBody), falKey, fastOptions);

    const downloadCall = fetchMock.mock.calls.find((call) => call[0] === modelFileURL);
    expect(downloadCall).toBeDefined();
    expect(new Headers(downloadCall?.[1].headers).get("authorization")).toBeNull();
    const usageLine = logSpy.mock.calls.map((call) => String(call[0])).find((line) => line.startsWith("[/try-it-model] usage ")) ?? "";
    expect(JSON.parse(usageLine.slice("[/try-it-model] usage ".length))).toMatchObject({
      model: "fal-ai/trellis-2",
      inferenceSeconds: 31.5,
      glbBytes: glbBytes.length,
      itemTitleLength: goodBody.itemTitle.length,
    });
    expect(usageLine).not.toContain(goodBody.itemTitle);
  });

  it("runs the fal model TRY_IT_MODEL_ENDPOINT names", async () => {
    const fetchMock = stubFal();

    await handleTryItModel(requestWithBody(goodBody), falKey, { ...fastOptions, endpoint: "fal-ai/hunyuan3d-v3/image-to-3d" });

    expect(fetchMock.mock.calls[0][0]).toBe("https://queue.fal.run/fal-ai/hunyuan3d-v3/image-to-3d");
  });

  it("runs TRELLIS 2 when TRY_IT_MODEL_ENDPOINT is empty", async () => {
    const fetchMock = stubFal();

    await handleTryItModel(requestWithBody(goodBody), falKey, { ...fastOptions, endpoint: "" });

    expect(fetchMock.mock.calls[0][0]).toBe(submitURL);
  });

  it("answers 504 without a request when the deadline has already passed", async () => {
    const fetchMock = stubFal();

    const response = await handleTryItModel(requestWithBody(goodBody), falKey, { ...fastOptions, wholeCallTimeoutMilliseconds: 0 });

    expect(response.status).toBe(504);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("answers 502 when the result answers an error status, even with a GLB named in its body", async () => {
    stubFal({ result: () => Response.json({ model_glb: { url: modelFileURL } }, { status: 500 }) });

    const response = await handleTryItModel(requestWithBody(goodBody), falKey, fastOptions);

    expect(response.status).toBe(502);
  });

  it("answers 502 when the GLB download answers an error status, even with GLB bytes", async () => {
    stubFal({ download: () => new Response(glbBytes, { status: 404 }) });

    const response = await handleTryItModel(requestWithBody(goodBody), falKey, fastOptions);

    expect(response.status).toBe(502);
  });

  it("logs that the result named no GLB", async () => {
    stubFal({ result: () => Response.json({ seed: 3 }) });
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);

    await handleTryItModel(requestWithBody(goodBody), falKey, fastOptions);

    expect(errorSpy.mock.calls.map((call) => String(call[0]))).toContain("[/try-it-model] the result named no GLB");
  });

  it("never calls a cancel URL off fal's queue", async () => {
    const fetchMock = stubFal({
      submit: () => Response.json({ request_id: "request-1", status_url: statusURL, response_url: responseURL, cancel_url: "https://evil.example/cancel" }),
      statuses: [{ status: "IN_PROGRESS" }],
    });

    const response = await handleTryItModel(requestWithBody(goodBody), falKey, { statusPollIntervalMilliseconds: 5, wholeCallTimeoutMilliseconds: 40 });

    expect(response.status).toBe(504);
    expect(calledURLs(fetchMock)).not.toContain("https://evil.example/cancel");
  });

  it("reads the GLB from model_mesh when the model names it so", async () => {
    stubFal({ result: () => Response.json({ model_mesh: { url: modelFileURL } }) });

    const response = await handleTryItModel(requestWithBody(goodBody), falKey, fastOptions);

    expect(response.status).toBe(200);
  });

  it("holds a GLB to the app's own limit, GLBLoader.largestFileByteCount, so the app never refuses a download it paid for", () => {
    expect(largestModelByteCount).toBe(40_000_000);
  });

  it("answers 503 before any call when FAL_KEY is not set, whatever the body", async () => {
    const fetchMock = stubFal();

    for (const unsetKey of [undefined, ""]) {
      for (const body of [goodBody, {}]) {
        const response = await handleTryItModel(requestWithBody(body), unsetKey, fastOptions);

        expect(response.status).toBe(503);
        expect(await response.json()).toEqual({ error: "FAL_KEY is not set" });
      }
    }
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it.each(["https://evil.example/collect", "fal-ai", "../fal-ai/trellis-2", "fal-ai/trellis-2?x=1"])(
    "answers 503 before any call for a TRY_IT_MODEL_ENDPOINT of %s, which is not a fal model id",
    async (endpoint) => {
      const fetchMock = stubFal();

      const response = await handleTryItModel(requestWithBody(goodBody), falKey, { ...fastOptions, endpoint });

      expect(response.status).toBe(503);
      expect(fetchMock).not.toHaveBeenCalled();
    },
  );

  it.each([
    ["no photo", { itemTitle: "Chair" }],
    ["an empty photo", { productJPEGBase64: "", itemTitle: "Chair" }],
    ["a photo over the cap", { productJPEGBase64: "A".repeat(4_000_001), itemTitle: "Chair" }],
    ["no title", { productJPEGBase64: "cHJvZHVjdA==" }],
    ["a title over 300 characters", { productJPEGBase64: "cHJvZHVjdA==", itemTitle: "x".repeat(301) }],
  ])("answers 400 for %s, before any call", async (_name, body) => {
    const fetchMock = stubFal();

    const response = await handleTryItModel(requestWithBody(body), falKey, fastOptions);

    expect(response.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("accepts a title of exactly 300 characters", async () => {
    stubFal();

    const response = await handleTryItModel(requestWithBody({ ...goodBody, itemTitle: "x".repeat(300) }), falKey, fastOptions);

    expect(response.status).toBe(200);
  });

  it.each([
    ["the submit answers 401", { submit: () => Response.json({ detail: "bad key" }, { status: 401 }) }],
    ["the submit answers something that is not JSON", { submit: () => new Response("<html></html>", { status: 200 }) }],
    ["the submit names no request", { submit: () => Response.json({ ok: true }) }],
    ["the request ends with an error", { statuses: [{ status: "COMPLETED", error: "CUDA out of memory", error_type: "runtime_error" }] }],
    ["a status check answers an unknown status", { statuses: [{ status: "EXPLODED" }] }],
    ["a status check answers no status", { statuses: [{ queue_position: 1 }] }],
    ["the result names no GLB", { result: () => Response.json({ seed: 3 }) }],
    ["the result answers 500", { result: () => new Response("oops", { status: 500 }) }],
    ["the GLB download answers 404", { download: () => new Response("gone", { status: 404 }) }],
    ["the downloaded file is not a GLB", { download: () => new Response(new Uint8Array([1, 2, 3, 4, 5]), { status: 200 }) }],
  ])("answers 502 when %s", async (_name, fakeFal: FakeFal) => {
    stubFal(fakeFal);

    const response = await handleTryItModel(requestWithBody(goodBody), falKey, fastOptions);

    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "The 3D model could not be made" });
  });

  it("answers 502 without following a status URL off fal's queue, so the key never leaves it", async () => {
    const fetchMock = stubFal({
      submit: () => Response.json({ request_id: "request-1", status_url: "https://evil.example/status", response_url: responseURL }),
    });

    const response = await handleTryItModel(requestWithBody(goodBody), falKey, fastOptions);

    expect(response.status).toBe(502);
    expect(calledURLs(fetchMock)).toEqual([submitURL]);
  });

  it("answers 502 without following a result URL off fal's queue", async () => {
    const fetchMock = stubFal({
      submit: () => Response.json({ request_id: "request-1", status_url: statusURL, response_url: "http://queue.fal.run/fal-ai/trellis-2/requests/request-1" }),
    });

    const response = await handleTryItModel(requestWithBody(goodBody), falKey, fastOptions);

    expect(response.status).toBe(502);
    expect(calledURLs(fetchMock)).toEqual([submitURL]);
  });

  it("answers 502 without downloading a GLB whose URL is not https", async () => {
    const fetchMock = stubFal({ result: () => Response.json({ model_glb: { url: "http://v3.fal.media/files/lion/model.glb" } }) });

    const response = await handleTryItModel(requestWithBody(goodBody), falKey, fastOptions);

    expect(response.status).toBe(502);
    expect(calledURLs(fetchMock)).not.toContain("http://v3.fal.media/files/lion/model.glb");
  });

  it("answers 502 for a GLB whose stated length passes the 40 MB cap", async () => {
    stubFal({
      download: () => new Response(glbBytes, { status: 200, headers: { "content-length": String(largestModelByteCount + 1) } }),
    });

    const response = await handleTryItModel(requestWithBody(goodBody), falKey, fastOptions);

    expect(response.status).toBe(502);
  });

  it("answers 502 for a GLB that passes the 40 MB cap as it arrives, with no stated length", async () => {
    const oneMegabyte = new Uint8Array(1024 * 1024);
    oneMegabyte.set(glbBytes.subarray(0, 4));
    let chunksSent = 0;
    stubFal({
      download: () =>
        new Response(
          new ReadableStream<Uint8Array>({
            pull(controller) {
              chunksSent += 1;
              controller.enqueue(oneMegabyte);
            },
          }),
          { status: 200 },
        ),
    });

    const response = await handleTryItModel(requestWithBody(goodBody), falKey, fastOptions);

    expect(response.status).toBe(502);
    expect(chunksSent).toBeLessThanOrEqual(42);
  });

  it("keeps a GLB of exactly 40 MB", async () => {
    const exactlyAtTheCap = new Uint8Array(largestModelByteCount);
    exactlyAtTheCap.set(glbBytes.subarray(0, 4));
    stubFal({ download: () => new Response(exactlyAtTheCap, { status: 200 }) });

    const response = await handleTryItModel(requestWithBody(goodBody), falKey, fastOptions);

    expect(response.status).toBe(200);
  });

  it("answers 502 when fal cannot be reached", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => {
      throw new TypeError("fetch failed");
    }));
    vi.spyOn(console, "error").mockImplementation(() => undefined);

    const response = await handleTryItModel(requestWithBody(goodBody), falKey, fastOptions);

    expect(response.status).toBe(502);
  });

  it("answers 504 and cancels the request when the model is not ready before the deadline", async () => {
    const fetchMock = stubFal({ statuses: [{ status: "IN_PROGRESS" }] });

    const response = await handleTryItModel(requestWithBody(goodBody), falKey, { statusPollIntervalMilliseconds: 5, wholeCallTimeoutMilliseconds: 60 });

    expect(response.status).toBe(504);
    expect(await response.json()).toEqual({ error: "The 3D model took too long to make" });
    const cancelCall = fetchMock.mock.calls.find((call) => call[0] === cancelURL);
    expect(cancelCall?.[1].method).toBe("PUT");
    expect(new Headers(cancelCall?.[1].headers).get("authorization")).toBe("Key fal-test-key");
  });

  it("answers 504 when a request to fal hangs past the deadline", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        (_url: string, init: RequestInit = {}) =>
          new Promise<Response>((_resolve, reject) => {
            init.signal?.addEventListener("abort", () => reject(init.signal?.reason));
          }),
      ),
    );
    vi.spyOn(console, "error").mockImplementation(() => undefined);

    const response = await handleTryItModel(requestWithBody(goodBody), falKey, { statusPollIntervalMilliseconds: 1, wholeCallTimeoutMilliseconds: 30 });

    expect(response.status).toBe(504);
  });

  it("does not cancel a request that already finished when the download fails", async () => {
    const fetchMock = stubFal({ download: () => new Response("gone", { status: 404 }) });

    await handleTryItModel(requestWithBody(goodBody), falKey, fastOptions);

    expect(calledURLs(fetchMock)).not.toContain(cancelURL);
  });
});
