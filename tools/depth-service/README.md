# Depth service

A local HTTP service that measures the wall in one camera frame with Apple's [Depth Pro](https://github.com/apple/ml-depth-pro).
Clicky's "show this art in my room" feature sends it a frame and an anchor pixel.
It replies with a placement frame on the wall at that pixel: a center, and a level right and up direction, all in meters in the camera's frame.

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

## API

`GET /health` returns `{ "ok": true }`.

`POST /wall` takes JSON:

| Field | Type | Meaning |
|-------|------|---------|
| `jpegBase64` | string | The camera frame as a base64 JPEG |
| `maskPngBase64` | string, optional | A base64 PNG of the person mask at any size, white = person |
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
`400` is a bad body (invalid JSON, base64 or image, an anchor outside the frame, a bad `focalPx`).
`403` is a request with an `Origin` header, and `415` a body whose `Content-Type` is not `application/json`, so a web page in a browser on this Mac cannot reach the service. The Worker sends `application/json` and no `Origin`.
`422` means under 200 bare wall points remain around the anchor, or the plane has a NaN or infinite number, such as a wall seen edge on.
`500` is a model failure.

## Measured

On a MacBook Air (M-series), a 1920 x 1080 frame takes about 14 to 16 seconds per wall once the model is warm (inference 16.1 s, the rest of the 16.5 s is decoding and the plane fit).
The first request after a start was slower (31 s).
A real room frame with a wall about 3 m away measured 3.83 m.

## Tests

```bash
uv run pytest -q
```

The tests build a synthetic tilted wall with noise and an object in front, and check the normal within 1 degree, the person mask, the center on the anchor's ray, a plane with a NaN refused, and that RANSAC on 42,000 points takes under 0.5 s.
`test_server.py` runs the real HTTP handler on a free port with no Depth Pro loaded, and checks the `Origin` and `Content-Type` refusals and the 422 for a wall it cannot measure.
