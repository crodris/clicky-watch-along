/**
 * POST /try-it-model.
 *
 * The app sends the furniture's product photo cut out on white, and the Worker turns it into a 3D model (a GLB) with
 * fal.ai's hosted image-to-3D, TRELLIS 2 unless `TRY_IT_MODEL_ENDPOINT` names another fal model. This gives a turnable
 * model for any furniture page with a photo, where only a few pages publish one. The Worker caches nothing: the app keeps
 * each model on disk by a hash of its inputs, so the same product is never paid for twice.
 *
 * fal runs a request through its queue: submit, poll the status until it is COMPLETED, read the result, then download
 * the GLB from the URL the result names (https://fal.ai/docs/model-apis/model-endpoints/queue).
 */

import { z } from "zod";
import { jsonResponse, parseJSONRequest } from "./anthropic";

const routeName = "/try-it-model";

/** TRELLIS 2 returns a textured GLB in `model_glb` (https://fal.ai/models/fal-ai/trellis-2/api). */
export const defaultTryItModelEndpoint = "fal-ai/trellis-2";
/** Every fal request carries the key, so it only ever goes to the queue's own origin, never to a URL a reply names. */
const falQueueOrigin = "https://queue.fal.run";
/** The whole call, from the submit to the last byte of the GLB. Past this the panel says it failed. */
const wholeCallTimeoutMilliseconds = 120_000;
const statusPollIntervalMilliseconds = 1_500;
/**
 * A 2048 texture and a 500,000 face mesh, TRELLIS 2's defaults, make a GLB of about 20 to 30 MB. This is the app's own limit,
 * `GLBLoader.largestFileByteCount`, so the Worker never returns a file the app would refuse after the download.
 */
export const largestModelByteCount = 40_000_000;

const maximumImageBase64Length = 4_000_000;
const maximumItemTitleLength = 300;

const tryItModelRequestSchema = z.object({
  productJPEGBase64: z.string().min(1).max(maximumImageBase64Length),
  // TRELLIS 2 takes no prompt, so the title is only checked and its length logged. The log never holds its text.
  itemTitle: z.string().max(maximumItemTitleLength),
});

/** A fal model id: an owner and a model, with optional subpaths, so the variable cannot name a whole URL. */
const falEndpointPattern = /^[a-z0-9][a-z0-9-]*(\/[a-z0-9][a-z0-9._-]*)+$/;

const submitReplySchema = z.object({ request_id: z.string(), status_url: z.string(), response_url: z.string(), cancel_url: z.string().optional() });
const statusReplySchema = z.object({
  status: z.string(),
  error: z.unknown().optional(),
  metrics: z.object({ inference_time: z.number().nullish() }).partial().optional(),
});
const fileSchema = z.object({ url: z.string() });
/** TRELLIS 2 names the GLB `model_glb`, and fal's other image-to-3D models, such as Hunyuan3D, `model_mesh`. */
const resultReplySchema = z.object({ model_glb: fileSchema.optional(), model_mesh: fileSchema.optional() });

class TryItModelFailure extends Error {
  constructor(
    readonly status: 502 | 504,
    logMessage: string,
  ) {
    super(logMessage);
  }
}

function isOnTheFalQueue(urlText: string): boolean {
  try {
    return new URL(urlText).origin === falQueueOrigin;
  } catch {
    return false;
  }
}

function isAnHTTPSURL(urlText: string): boolean {
  try {
    return new URL(urlText).protocol === "https:";
  } catch {
    return false;
  }
}

/** Every GLB starts with the ASCII magic "glTF". */
function startsWithGLBMagic(bytes: Uint8Array): boolean {
  return bytes.length >= 4 && bytes[0] === 0x67 && bytes[1] === 0x6c && bytes[2] === 0x54 && bytes[3] === 0x46;
}

export type TryItModelOptions = {
  /** The fal model id, from `TRY_IT_MODEL_ENDPOINT`. */
  endpoint?: string;
  wholeCallTimeoutMilliseconds?: number;
  statusPollIntervalMilliseconds?: number;
};

export async function handleTryItModel(request: Request, falKey: string | undefined, options: TryItModelOptions = {}): Promise<Response> {
  // Checked before the body, so an install without fal set up hears so whatever it sent.
  if (falKey === undefined || falKey === "") {
    return jsonResponse({ error: "FAL_KEY is not set" }, 503);
  }
  const endpoint = options.endpoint === undefined || options.endpoint === "" ? defaultTryItModelEndpoint : options.endpoint;
  if (!falEndpointPattern.test(endpoint)) {
    console.error(`[${routeName}] TRY_IT_MODEL_ENDPOINT is not a fal model id`);
    return jsonResponse({ error: "TRY_IT_MODEL_ENDPOINT is not a fal model id" }, 503);
  }

  const parsedRequest = await parseJSONRequest(request, tryItModelRequestSchema);
  if (!parsedRequest.ok) {
    return parsedRequest.response;
  }
  const { productJPEGBase64, itemTitle } = parsedRequest.requestBody;

  const startedAt = Date.now();
  const deadline = startedAt + (options.wholeCallTimeoutMilliseconds ?? wholeCallTimeoutMilliseconds);
  const pollInterval = options.statusPollIntervalMilliseconds ?? statusPollIntervalMilliseconds;
  const falHeaders = { authorization: `Key ${falKey}`, "content-type": "application/json" };
  let cancelURL: string | undefined;

  /** Each request gets only the time left, so one slow step cannot carry the call past its deadline. */
  async function fetchBeforeTheDeadline(url: string, init: RequestInit, stepName: string): Promise<Response> {
    const millisecondsLeft = deadline - Date.now();
    if (millisecondsLeft <= 0) {
      throw new TryItModelFailure(504, `ran out of time before ${stepName}`);
    }
    try {
      return await fetch(url, { ...init, signal: AbortSignal.timeout(millisecondsLeft) });
    } catch (error) {
      const ranOutOfTime = error instanceof Error && (error.name === "TimeoutError" || error.name === "AbortError");
      throw new TryItModelFailure(ranOutOfTime ? 504 : 502, `${stepName} ${ranOutOfTime ? "ran out of time" : "got no answer"}`);
    }
  }

  async function jsonOf(response: Response, stepName: string): Promise<unknown> {
    if (!response.ok) {
      const errorText = (await response.text()).slice(0, 500).replace(/[\r\n\v\f\u0085\u2028\u2029]/g, " ");
      throw new TryItModelFailure(502, `${stepName} answered ${response.status}: ${errorText}`);
    }
    try {
      return await response.json();
    } catch {
      throw new TryItModelFailure(502, `${stepName} answered with something that is not JSON`);
    }
  }

  try {
    const submitReply = submitReplySchema.safeParse(
      await jsonOf(
        await fetchBeforeTheDeadline(
          `${falQueueOrigin}/${endpoint}`,
          { method: "POST", headers: falHeaders, body: JSON.stringify({ image_url: `data:image/jpeg;base64,${productJPEGBase64}` }) },
          "the submit",
        ),
        "the submit",
      ),
    );
    if (!submitReply.success) {
      throw new TryItModelFailure(502, "the submit's reply named no request");
    }
    const { status_url: statusURL, response_url: responseURL } = submitReply.data;
    if (!isOnTheFalQueue(statusURL) || !isOnTheFalQueue(responseURL)) {
      throw new TryItModelFailure(502, "the submit named a status or result URL off fal's queue");
    }
    if (submitReply.data.cancel_url !== undefined && isOnTheFalQueue(submitReply.data.cancel_url)) {
      cancelURL = submitReply.data.cancel_url;
    }

    let inferenceSeconds: number | undefined;
    for (;;) {
      const statusReply = statusReplySchema.safeParse(
        await jsonOf(await fetchBeforeTheDeadline(statusURL, { headers: falHeaders }, "a status check"), "a status check"),
      );
      if (!statusReply.success) {
        throw new TryItModelFailure(502, "a status check answered with no status");
      }
      if (statusReply.data.status === "COMPLETED") {
        // A failed request also ends COMPLETED, with an error.
        if (statusReply.data.error !== undefined && statusReply.data.error !== null) {
          throw new TryItModelFailure(502, "fal finished the request with an error");
        }
        inferenceSeconds = statusReply.data.metrics?.inference_time ?? undefined;
        break;
      }
      if (statusReply.data.status !== "IN_QUEUE" && statusReply.data.status !== "IN_PROGRESS") {
        throw new TryItModelFailure(502, "a status check answered an unknown status");
      }
      // A sleep that runs past the deadline ends at the next status check, which refuses to start and answers 504.
      await new Promise((resolve) => setTimeout(resolve, pollInterval));
    }
    cancelURL = undefined;

    const resultReply = resultReplySchema.safeParse(
      await jsonOf(await fetchBeforeTheDeadline(responseURL, { headers: falHeaders }, "the result"), "the result"),
    );
    const modelURL = resultReply.success ? (resultReply.data.model_glb ?? resultReply.data.model_mesh)?.url : undefined;
    if (modelURL === undefined) {
      throw new TryItModelFailure(502, "the result named no GLB");
    }
    if (!isAnHTTPSURL(modelURL)) {
      throw new TryItModelFailure(502, "the result's GLB URL is not https");
    }

    // The file URL is fal's public storage, so the download carries no key.
    const modelResponse = await fetchBeforeTheDeadline(modelURL, {}, "the GLB download");
    if (!modelResponse.ok || modelResponse.body === null) {
      throw new TryItModelFailure(502, `the GLB download answered ${modelResponse.status}`);
    }
    const announcedLength = Number(modelResponse.headers.get("content-length") ?? "0");
    if (announcedLength > largestModelByteCount) {
      await modelResponse.body.cancel();
      throw new TryItModelFailure(502, `the GLB is ${announcedLength} bytes, over the ${largestModelByteCount} byte cap`);
    }
    // Counted as it arrives too, since a server can leave out or understate its length.
    const modelParts: Uint8Array[] = [];
    let modelByteCount = 0;
    const modelReader = modelResponse.body.getReader();
    for (;;) {
      let readResult: ReadableStreamReadResult<Uint8Array>;
      try {
        readResult = await modelReader.read();
      } catch {
        throw new TryItModelFailure(Date.now() >= deadline ? 504 : 502, "the GLB download broke off");
      }
      if (readResult.done) break;
      modelByteCount += readResult.value.length;
      if (modelByteCount > largestModelByteCount) {
        await modelReader.cancel();
        throw new TryItModelFailure(502, `the GLB passed the ${largestModelByteCount} byte cap`);
      }
      modelParts.push(readResult.value);
    }
    const modelBytes = new Uint8Array(modelByteCount);
    let offset = 0;
    for (const part of modelParts) {
      modelBytes.set(part, offset);
      offset += part.length;
    }
    if (!startsWithGLBMagic(modelBytes)) {
      throw new TryItModelFailure(502, "the downloaded file is not a GLB");
    }

    console.log(
      `[${routeName}] usage ${JSON.stringify({
        model: endpoint,
        inferenceSeconds,
        seconds: (Date.now() - startedAt) / 1000,
        glbBytes: modelByteCount,
        itemTitleLength: itemTitle.length,
      })}`,
    );
    return new Response(modelBytes, { status: 200, headers: { "content-type": "application/octet-stream" } });
  } catch (error) {
    if (!(error instanceof TryItModelFailure)) {
      throw error;
    }
    console.error(`[${routeName}] ${error.message}`);
    // A request still queued or running when the call gives up would keep spending, so it is cancelled. The cancel's own
    // outcome changes nothing for the app.
    if (cancelURL !== undefined) {
      await fetch(cancelURL, { method: "PUT", headers: falHeaders, signal: AbortSignal.timeout(5_000) }).catch(() => undefined);
    }
    return jsonResponse(
      { error: error.status === 504 ? "The 3D model took too long to make" : "The 3D model could not be made" },
      error.status,
    );
  }
}
