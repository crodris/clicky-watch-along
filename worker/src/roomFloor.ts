/**
 * POST /room-floor.
 *
 * The same request as /room-wall, where the anchor is the pixel the furniture's front-bottom center stands on. The Worker
 * forwards it to the depth service's /floor, which measures the floor plane under the anchor and returns a placement frame
 * on it: `center`, a `right` that lies on the floor and is level with the camera, `up` (the floor's normal, pointing up),
 * and `forward` (up x right, on the floor, pointing away from the camera). The forwarding and its error mapping are shared
 * with /room-wall (`depthService.ts`).
 */

import { z } from "zod";
import { forwardToDepthService, planeReplyShape } from "./depthService";

/** A floor nearer than this or farther than this is a misread, not a room. */
const nearestPlausibleFloorMeters = 0.3;
const farthestPlausibleFloorMeters = 12;
/** Under this share of the points near the anchor on one plane, the patch is not one flat floor. */
const leastPlausibleInlierShare = 0.3;
/**
 * The floor's tilt is the angle between its normal and the camera's vertical, which is how far the camera is pitched up or
 * down while the floor is seen. The service refuses a plane over 25 degrees, so this limit only trips for a service whose
 * own limit changed or broke. A hand-held camera aimed at the floor in a room sits well inside 30 degrees, and 90 is a
 * wall, so a value over 30 is not a floor to stand furniture on.
 */
const mostPlausibleFloorTiltDegrees = 30;

// Passthrough keeps any extra field the service reports, so the app reads the service's reply as it was sent.
const floorReplySchema = z
  .object({
    ...planeReplyShape,
    forward: z.tuple([z.number(), z.number(), z.number()]),
    floorTiltDegrees: z.number().min(0).max(90),
  })
  .passthrough();

type FloorReply = z.infer<typeof floorReplySchema>;

/** Why a measured floor cannot be a real floor to stand furniture on, or undefined when it can. */
function floorImplausibility({ distanceMeters, floorTiltDegrees, planeInlierShare }: FloorReply): string | undefined {
  if (distanceMeters < nearestPlausibleFloorMeters || distanceMeters > farthestPlausibleFloorMeters) {
    return `The floor measured ${distanceMeters} m away, outside ${nearestPlausibleFloorMeters} to ${farthestPlausibleFloorMeters} m`;
  }
  if (floorTiltDegrees > mostPlausibleFloorTiltDegrees) {
    return `The floor measured ${floorTiltDegrees} degrees from level, over ${mostPlausibleFloorTiltDegrees} degrees`;
  }
  if (planeInlierShare < leastPlausibleInlierShare) {
    return `Only ${Math.round(planeInlierShare * 100)} percent of the floor fits one plane, under ${leastPlausibleInlierShare * 100} percent`;
  }
  return undefined;
}

export function handleRoomFloor(request: Request, depthServiceURL: string | undefined): Promise<Response> {
  return forwardToDepthService(request, depthServiceURL, {
    routeName: "/room-floor",
    servicePath: "/floor",
    replySchema: floorReplySchema,
    implausibility: floorImplausibility,
    successLogLine: (reply, totalSeconds) =>
      `[/room-floor] distance ${reply.distanceMeters} m, tilt ${reply.floorTiltDegrees} deg, depth ${reply.inferenceSeconds} s, total ${totalSeconds.toFixed(1)} s`,
  });
}
