/**
 * POST /room-wall.
 *
 * The app sends a photo of the learner's room, an optional mask of the people in it, and the point on the
 * wall where the art should hang. The Worker forwards that body to the local depth service (tools/depth-service),
 * which measures the wall plane, and checks the reply before the app reads it. The forwarding and its error mapping
 * are shared with /room-floor (`depthService.ts`).
 */

import { z } from "zod";
import { forwardToDepthService, planeReplyShape } from "./depthService";

/** A wall nearer than this or farther than this is a misread, not a room. */
const nearestPlausibleWallMeters = 0.3;
const farthestPlausibleWallMeters = 12;
/** Under this share of the points near the anchor on one plane, the patch is not one flat wall. */
const leastPlausibleInlierShare = 0.3;

// Passthrough keeps any extra field the service reports, so the app reads the service's reply as it was sent.
const wallReplySchema = z.object({ ...planeReplyShape, wallAngleDegrees: z.number() }).passthrough();

type WallReply = z.infer<typeof wallReplySchema>;

/** Why a measured wall cannot be a real wall to hang art on, or undefined when it can. */
function wallImplausibility({ distanceMeters, planeInlierShare }: WallReply): string | undefined {
  if (distanceMeters < nearestPlausibleWallMeters || distanceMeters > farthestPlausibleWallMeters) {
    return `The wall measured ${distanceMeters} m away, outside ${nearestPlausibleWallMeters} to ${farthestPlausibleWallMeters} m`;
  }
  if (planeInlierShare < leastPlausibleInlierShare) {
    return `Only ${Math.round(planeInlierShare * 100)} percent of the wall fits one plane, under ${leastPlausibleInlierShare * 100} percent`;
  }
  return undefined;
}

export function handleRoomWall(request: Request, depthServiceURL: string | undefined): Promise<Response> {
  return forwardToDepthService(request, depthServiceURL, {
    routeName: "/room-wall",
    servicePath: "/wall",
    replySchema: wallReplySchema,
    implausibility: wallImplausibility,
    successLogLine: (reply, totalSeconds) =>
      `[/room-wall] distance ${reply.distanceMeters} m, angle ${reply.wallAngleDegrees} deg, depth ${reply.inferenceSeconds} s, total ${totalSeconds.toFixed(1)} s`,
  });
}
