# Depth service

A local HTTP service that measures the wall or the floor in one camera frame with Apple's [Depth Pro](https://github.com/apple/ml-depth-pro).
Clicky's "show this art in my room" feature sends `POST /wall` a frame and an anchor pixel.
It replies with a placement frame on the wall at that pixel: a center, and a level right and up direction, all in meters in the camera's frame.
Furniture uses `POST /floor`, which returns a placement frame on the floor under the anchor.

This is a local stand-in for a hosted GPU.
It runs on the Mac's own GPU (MPS) and binds to `127.0.0.1` only.

## How it measures

1. Depth Pro predicts a metric depth map and the focal length from the JPEG (or uses the `focalPx` you send).
2. The service samples every third pixel in a square around the anchor, drops the pixels under the person mask, and back-projects them to 3D points.
3. RANSAC on a random subset of 4,000 points finds the wall plane, and a least squares step on the inliers refines its normal.
4. The center is where the ray through the anchor meets the plane.
   `right` is horizontal and points to +x of the image.
   `up` points to -y of the image (up in the image).
   Both lie on the wall plane.

The floor follows the same steps with these differences:

- The window around the anchor is wider and reaches further below it than above it, since the floor runs down toward the camera.
- Inliers lie within 3 cm of the plane, since the floor is seen at a grazing angle.
- A plane whose normal is more than 25 degrees from the camera's vertical (the image's -y) is a wall or a table and is rejected.
- An anchor above the floor's horizon is rejected too, since its ray never reaches the floor in front of the camera.

Both routes share one Depth Pro run path (`infer_depth`, one lock), and each picks its own geometry from `GEOMETRY_BY_ROUTE`.

The geometry is in `plane.py` and has no torch import, so its tests run in seconds.

## Setup

Python 3.12 and [uv](https://docs.astral.sh/uv/) are required.

```bash
cd tools/depth-service
uv sync
mkdir -p checkpoints
curl -L -o checkpoints/depth_pro.pt https://ml-site.cdn-apple.com/models/depth-pro/depth_pro.pt
```

The checkpoint is 1.9 GB and is gitignored.
Point `DEPTH_PRO_CHECKPOINT` at another copy to skip the download.
The server exits with the download URL when the file is missing.

## Run

```bash
uv run server.py
```

| Variable | Default | Meaning |
|----------|---------|---------|
| `DEPTH_SERVICE_PORT` | `8801` | Port on `127.0.0.1` |
| `DEPTH_PRO_CHECKPOINT` | `tools/depth-service/checkpoints/depth_pro.pt` | Checkpoint file |

Loading the model takes 15 to 100 seconds, since the first load reads 1.9 GB and compiles for MPS.
The server prints `Depth service listening on ...` when it is ready, and `GET /health` answers then.
It runs one Depth Pro inference at a time.
It keeps the last two depth maps by a hash of the JPEG and the focal hint, so a second measurement of the same frame, such as furniture's wall after its floor, answers in under a second, and each reply says `depthWasCached`.

## API

`GET /health` returns `{ "ok": true }`.

`POST /wall` takes JSON:

| Field | Type | Meaning |
|-------|------|---------|
| `jpegBase64` | string | The camera frame as a base64 JPEG, at most 4096 px on a side. Any other format is refused |
| `maskPngBase64` | string, optional | A base64 PNG of the person mask, at most 4096 px on a side, white = person |
| `anchor` | `{ u, v }` | The pixel in the frame to place the art at |
| `focalPx` | number, optional | The camera's focal length in pixels, when known |

It replies `200` with:

```json
{
  "center": [-0.7956, -0.1193, 3.7425],
  "right": [0.99999, 0.0, 0.00342],
  "up": [-0.00086, -0.96773, 0.25199],
  "focalPx": 1881.57,
  "principal": [960.0, 540.0],
  "distanceMeters": 3.828,
  "wallAngleDegrees": 14.6,
  "planeInlierShare": 0.721,
  "inferenceSeconds": 16.09,
  "seconds": 16.49
}
```

Points are `[x, y, z]` in meters, x right, y down, z forward.
`principal` is the frame's center, in pixels.
`wallAngleDegrees` is the angle between the wall's normal and the camera's axis.
`planeInlierShare` is the share of sampled points within 2 cm of the plane.

Errors are `{ "error": "..." }`.
`400` is a bad body (invalid JSON, base64, a frame that is not a JPEG, an image or mask over 4096 px on a side, a mask that is not a PNG, an anchor outside the frame, a bad `focalPx`).
`403` is a request with an `Origin` header, and `415` a body whose `Content-Type` is not `application/json`, so a web page in a browser on this Mac cannot reach the service. The Worker sends `application/json` and no `Origin`.
`422` means under 200 bare wall points remain around the anchor, or the plane has a NaN or infinite number, such as a wall seen edge on.
`500` is a model failure.
The `/floor` route ran on one live Depth Pro frame (see Measured), and its geometry is tested on synthetic floors.

`POST /floor` takes the same body.
`anchor` is the pixel where the furniture's front-bottom center should stand.

It replies `200` with:

```json
{
  "center": [0.0, 0.354, 3.316],
  "right": [1.0, 0.0, 0.0],
  "up": [0.0, -0.96593, -0.25882],
  "forward": [0.0, -0.25882, 0.96593],
  "focalPx": 1500.0,
  "principal": [960.0, 540.0],
  "distanceMeters": 3.335,
  "floorTiltDegrees": 15.0,
  "planeInlierShare": 0.97,
  "inferenceSeconds": 16.09,
  "seconds": 16.49
}
```

The numbers above are synthetic (a floor seen from a camera 1.2 m high, pitched 15 degrees down), not a live measurement.
Points and directions are `[x, y, z]` in meters, x right, y down, z forward.

- `center` is the 3D point on the floor under the anchor.
- `up` is the floor normal, pointing up.
- `right` lies on the floor, level with the camera, toward +x of the image.
- `forward` = `up` x `right`. It lies on the floor and points away from the camera. `right` x `up` is its negation, and points toward the camera.
- `floorTiltDegrees` is the angle between `up` and the camera's vertical.
- `planeInlierShare` is the share of sampled floor points within 3 cm of the plane.

`right`, `up`, and `forward` are unit vectors at right angles to each other.

### Standing a box on the floor

For a box W wide, H tall, and D deep, with `center` as the middle of its front-bottom edge:

- The front face spans `center - right * W/2` to `center + right * W/2` on the floor, and rises H along `up`.
- The back face is the same rectangle moved D along `forward`.
- The bottom face lies in the floor plane, so the box stands on it at real size.

The eight corners are `center + right * (sx * W/2) + up * (sy * H) + forward * (sz * D)`, with `sx` of -1 or 1, `sy` of 0 or 1, and `sz` of 0 or 1.

`422` on `/floor` means under 200 bare floor points remain around the anchor, the plane under it is not floor-like (tilted over 25 degrees from the camera's vertical, or the anchor is above the horizon), or the plane has a NaN or infinite number.

### Tables and shelves

`POST /floor` also takes an optional `standsOn`, `"floor"` (the default) or `"tableOrShelf"`.
Any other value is a `400`, and `standsOn` on `/wall` is a `400` too.
With `"tableOrShelf"` the anchor is a click on the top of a table, desk, counter, or shelf, and the reply has the same shape.

A floor fit on a table top measured the wall behind it (86 degrees), since its window is 40% of the frame wide and RANSAC keeps the largest plane.
So the surface fit differs from the floor fit in two ways:

- The window is small: 6% of the frame's width to each side of the click, and 3% of the width above and below it.
- RANSAC scores only candidate planes whose normal is within 25 degrees of the camera's vertical, so a wall can never win over a small level top.
  Inliers lie within 1.5 cm of the plane.

The horizon and non-finite checks are the floor's.
`422` says "table or shelf" when under 200 bare points remain, no level plane lies at the click, or the click is above the surface's horizon.
On 2026-11-23 it measured a real table top in the room fixture at 4.9 degrees with 63% of the points on it, where the floor fit gave 86 degrees, and the floor under it still at 2.8 degrees.

## Measured

On a MacBook Air (M-series), a 1920 x 1080 frame takes about 14 to 16 seconds per wall once the model is warm (inference 16.1 s, the rest of the 16.5 s is decoding and the plane fit).
The first request after a start was slower (31 s).
A real room frame with a wall about 3 m away measured 3.83 m.

On 2026-11-21 `/floor` ran on a 1440 x 960 frame of a person standing in a room, shot from a low camera that looks up at the person, with no floor in view.
An anchor at the bottom right (1000, 930), on whatever low surface is there, gave a plane 1.29 m away, tilted 16.8 degrees from the camera's vertical (the camera pitched up about 17 degrees), with 47% of the points on it.
An anchor on the wall at (1000, 500) answered 422 "tilted 71 degrees".
Each took 12.9 s of Depth Pro inference.
No photo in hand shows a floor, so the 200 above is not a check that the plane is the floor.

## Tests

```bash
uv run pytest -q
```

The tests build a synthetic tilted wall with noise and an object in front, and check the normal within 1 degree, the person mask, the center on the anchor's ray, a plane with a NaN refused, and that RANSAC on 42,000 points takes under 2 s.
For the floor they build a floor seen from a camera 1.2 m high, pitched 15 degrees down, and check `up` within 2 degrees, the center on the anchor's ray and the floor, the orthonormal right, up, and forward with forward away from the camera, the rejection of a wall and of an anchor above the horizon, and the person mask.
For the surface fit they build a level table top as a thin band of rows in front of a wall, and check that the surface fit finds it where the floor fit measures the wall, and the "table or shelf" errors.
`test_server.py` runs the real HTTP handler on a free port with no Depth Pro loaded, and checks the `Origin` and `Content-Type` refusals on both routes, the 422 for a plane it cannot measure, the reply shape of each route with a stand-in for Depth Pro, and the 400 for a frame that is not a JPEG, an image or a mask over 4096 px on a side (refused from its header before any pixel is decoded), and a mask that is not a PNG.
