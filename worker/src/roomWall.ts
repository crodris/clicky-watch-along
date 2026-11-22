/**
 * POST /room-wall.
 *
 * The app sends a photo of the learner's room, an optional mask of the people in it, and the point on the
 * wall where the art should hang. The Worker forwards that body to the local depth service (tools/depth-service),
 * which measures the wall plane, and checks the reply before the app reads it. The Worker holds the service's
 * address, so the app never learns where it runs.
 *
 * A wall the service could not measure (its 422) and a wall too near, too far, or not flat enough answer 422, which the
 * app reads as "point the camera at a bare wall". A service that is down, slow, failing, or answering garbage answers 502.
 */

import { z } from "zod";
import { jsonResponse, parseJSONRequest } from "./anthropic";

const maximumJPEGBase64Length = 4_000_000;
const maximumMaskBase64Length = 1_000_000;
const depthServiceTimeoutMilliseconds = 60_000;
const maximumServiceErrorLength = 300;
/** A wall nearer than this or farther than this is a misread, not a room. */
const nearestPlausibleWallMeters = 0.3;
const farthestPlausibleWallMeters = 12;
/** Under this share of the points near the anchor on one plane, the patch is not one flat wall. */
const leastPlausibleInlierShare = 0.3;

const roomWallRequestSchema = z.object({
  jpegBase64: z.string().min(1).max(maximumJPEGBase64Length),
  maskPngBase64: z.string().min(1).max(maximumMaskBase64Length).optional(),
  anchor: z.object({ u: z.number().finite(), v: z.number().finite() }),
});

const vector3Schema = z.tuple([z.number(), z.number(), z.number()]);

// Passthrough keeps any extra field the service reports, so the app reads the service's reply as it was sent.
const depthServiceReplySchema = z
  .object({
    center: vector3Schema,
    right: vector3Schema,
    up: vector3Schema,
    focalPx: z.number().positive(),
    principal: z.tuple([z.number(), z.number()]),
    distanceMeters: z.number().positive(),
    wallAngleDegrees: z.number(),
    planeInlierShare: z.number().min(0).max(1),
    inferenceSeconds: z.number(),
    seconds: z.number(),
  })
  .passthrough();

/** The service's error as one line: its JSON `error` field when it has one, else its text, with whitespace collapsed. */
function serviceErrorOnOneLine(errorBodyText: string): string {
  let errorText = errorBodyText;
  try {
    const errorJSON: unknown = JSON.parse(errorBodyText);
    if (typeof errorJSON === "object" && errorJSON !== null && "error" in errorJSON && typeof errorJSON.error === "string") {
      errorText = errorJSON.error;
    }
  } catch {
    // Not JSON, so the text itself is the error.
  }
  const oneLine = errorText.replace(/\s+/g, " ").trim().slice(0, maximumServiceErrorLength);
  return oneLine.length > 0 ? oneLine : "no error text";
}

/** Why a measured wall cannot be a real wall to hang art on, or undefined when it can. */
function wallImplausibility(distanceMeters: number, planeInlierShare: number): string | undefined {
  if (distanceMeters < nearestPlausibleWallMeters || distanceMeters > farthestPlausibleWallMeters) {
    return `The wall measured ${distanceMeters} m away, outside ${nearestPlausibleWallMeters} to ${farthestPlausibleWallMeters} m`;
  }
  if (planeInlierShare < leastPlausibleInlierShare) {
    return `Only ${Math.round(planeInlierShare * 100)} percent of the wall fits one plane, under ${leastPlausibleInlierShare * 100} percent`;
  }
  return undefined;
}

export async function handleRoomWall(request: Request, depthServiceURL: string | undefined): Promise<Response> {
  const parsedRequest = await parseJSONRequest(request, roomWallRequestSchema);
  if (!parsedRequest.ok) {
    return parsedRequest.response;
  }
  if (depthServiceURL === undefined || depthServiceURL === "") {
    return jsonResponse({ error: "The depth service isn't configured" }, 503);
  }

  const startedAtMilliseconds = Date.now();
  let serviceResponse: Response;
  try {
    serviceResponse = await fetch(`${depthServiceURL.replace(/\/+$/, "")}/wall`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(parsedRequest.requestBody),
      signal: AbortSignal.timeout(depthServiceTimeoutMilliseconds),
    });
  } catch (error) {
    console.error("[/room-wall] The depth service request failed:", error);
    return jsonResponse({ error: "The depth service could not be reached" }, 502);
  }

  const serviceReplyText = await serviceResponse.text();
  if (!serviceResponse.ok) {
    const serviceError = serviceErrorOnOneLine(serviceReplyText);
    console.error(`[/room-wall] The depth service answered ${serviceResponse.status}: ${serviceError}`);
    // A 422 is the service measuring the photo and finding no wall to hang on, so the app asks for a bare wall.
    // Every other status means the service itself failed, and the app asks whether it runs.
    if (serviceResponse.status === 422) {
      return jsonResponse({ error: serviceError }, 422);
    }
    return jsonResponse({ error: `The depth service answered ${serviceResponse.status}: ${serviceError}` }, 502);
  }

  let serviceReplyJSON: unknown;
  try {
    serviceReplyJSON = JSON.parse(serviceReplyText);
  } catch {
    return jsonResponse({ error: "The depth service's reply was not JSON" }, 502);
  }
  const parsedReply = depthServiceReplySchema.safeParse(serviceReplyJSON);
  if (!parsedReply.success) {
    const problem = parsedReply.error.issues.map((issue) => `${issue.path.join(".")}: ${issue.message}`).join("; ");
    console.error(`[/room-wall] The depth service's reply failed validation: ${problem}`);
    return jsonResponse({ error: `The depth service's reply was not what the Worker expects: ${problem}` }, 502);
  }

  const reply = parsedReply.data;
  const implausibility = wallImplausibility(reply.distanceMeters, reply.planeInlierShare);
  if (implausibility !== undefined) {
    console.error(`[/room-wall] The measured wall is not plausible: ${implausibility}`);
    return jsonResponse({ error: implausibility }, 422);
  }
  const totalSeconds = (Date.now() - startedAtMilliseconds) / 1000;
  console.log(
    `[/room-wall] distance ${reply.distanceMeters} m, angle ${reply.wallAngleDegrees} deg, depth ${reply.inferenceSeconds} s, total ${totalSeconds.toFixed(1)} s`,
  );
  return jsonResponse(reply, 200);
}
