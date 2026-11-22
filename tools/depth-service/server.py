"""Local depth service: measures the wall or the floor in one camera frame with Apple's Depth Pro.

GET  /health -> {"ok": true}
POST /wall   -> { jpegBase64, maskPngBase64?, anchor: { u, v }, focalPx? }
                200 { center, right, up, focalPx, principal, distanceMeters, wallAngleDegrees,
                      planeInlierShare, inferenceSeconds, seconds }
                400 { error } for a bad body (a frame that is not a JPEG, or an image or mask side over 4096 pixels,
                included, the size read from the header before any pixel is decoded), 422 { error } when under 200 bare wall points remain
                or the plane is not finite.
POST /floor  -> the same body, where anchor is the pixel the furniture's front-bottom center stands on.
                200 { center, right, up, forward, focalPx, principal, distanceMeters,
                      floorTiltDegrees, planeInlierShare, inferenceSeconds, seconds }
                400 { error } for a bad body, 422 { error } when under 200 bare floor points remain, the
                plane is a wall or a table, not a floor, or the plane is not finite.
Both routes answer 403 for a request with an Origin header and 415 for a body that is not
application/json, so a web page in a browser on this Mac cannot reach the service.

Depth Pro loads once at start. `plane.py` holds the geometry and has no torch import.
The last two depth maps are kept by a hash of the JPEG and the focal hint, so furniture's wall
measurement on the same keyframe as its floor measurement costs no second Depth Pro run.
"""

import base64
import binascii
import collections
import dataclasses
import hashlib
import io
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import cv2
import numpy as np
from PIL import Image, UnidentifiedImageError

import plane

CHECKPOINT_DOWNLOAD_URL = "https://ml-site.cdn-apple.com/models/depth-pro/depth_pro.pt"
DEFAULT_CHECKPOINT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "checkpoints", "depth_pro.pt")
DEFAULT_PORT = 8801
MAX_BODY_BYTES = 40_000_000
# The most pixels either image may span on a side. The panel's frame is 1280 x 720, so this is generous, and it keeps a
# small file that declares a huge image from filling memory in the decode.
MAX_IMAGE_SIDE = 4096
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
# A person mask pixel counts as a person above this gray value.
PERSON_MASK_THRESHOLD = 100

# One Depth Pro run at a time: parallel runs share the GPU and each takes longer.
DEPTH_LOCK = threading.Lock()
# Furniture measures the floor and then the wall on one keyframe, so the last depth maps are kept.
# Two cover that pair and a click's new keyframe, at about 4 MB each for a 1280 x 720 frame.
DEPTH_CACHE_SIZE = 2
DEPTH_CACHE_LOCK = threading.Lock()
depth_cache = collections.OrderedDict()
depth_model = None
depth_transform = None
depth_device = None


class BadRequestError(ValueError):
    """The request body is not a valid /wall or /floor request."""


def load_depth_pro(checkpoint_path):
    # torch and depth_pro are imported here so `plane.py` and its tests never pay for them.
    import depth_pro
    import torch

    global depth_model, depth_transform, depth_device
    depth_device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    config = dataclasses.replace(depth_pro.depth_pro.DEFAULT_MONODEPTH_CONFIG_DICT, checkpoint_uri=checkpoint_path)
    started_at = time.time()
    depth_model, depth_transform = depth_pro.create_model_and_transforms(config=config, device=depth_device, precision=torch.float16)
    depth_model.eval()
    print(f"Depth Pro loaded in {time.time() - started_at:.1f} s on {depth_device}", flush=True)


def depth_cache_key(jpeg_base64, focal_hint):
    """The same JPEG and focal hint give the same depth, so their hash names a cached run."""
    return hashlib.sha256(f"{jpeg_base64}|{focal_hint!r}".encode()).hexdigest()


def cached_depth(cache_key, frame_rgb, focal_hint):
    """(depth, focal length, whether it came from the cache). A miss runs Depth Pro and keeps the result.

    Two requests for the same frame that arrive together may both run Depth Pro; the app sends the
    wall request only after the floor's reply, so that never happens in practice.
    """
    with DEPTH_CACHE_LOCK:
        if cache_key in depth_cache:
            depth_cache.move_to_end(cache_key)
            depth_m, focal_px = depth_cache[cache_key]
            return depth_m, focal_px, True
    depth_m, focal_px = infer_depth(frame_rgb, focal_hint)
    with DEPTH_CACHE_LOCK:
        depth_cache[cache_key] = (depth_m, focal_px)
        depth_cache.move_to_end(cache_key)
        while len(depth_cache) > DEPTH_CACHE_SIZE:
            depth_cache.popitem(last=False)
    return depth_m, focal_px, False


def infer_depth(frame_rgb, focal_hint):
    """Returns (depth in meters at the frame's size, focal length in pixels)."""
    import torch

    image_height, image_width = frame_rgb.shape[:2]
    with DEPTH_LOCK, torch.no_grad():
        prediction = depth_model.infer(
            depth_transform(frame_rgb),
            f_px=torch.tensor(float(focal_hint), device=depth_device) if focal_hint else None,
        )
    depth_m = prediction["depth"].float().cpu().numpy()
    if depth_m.shape != (image_height, image_width):
        depth_m = cv2.resize(depth_m, (image_width, image_height))
    return depth_m, float(prediction["focallength_px"])


def decode_base64(value, field_name):
    if not isinstance(value, str) or not value:
        raise BadRequestError(f"{field_name} must be a non-empty base64 string")
    try:
        return base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        raise BadRequestError(f"{field_name} is not valid base64")


def refuse_an_image_over_the_side_limit(field_name, image_width, image_height):
    if image_width > MAX_IMAGE_SIDE or image_height > MAX_IMAGE_SIDE:
        raise BadRequestError(f"{field_name} is {image_width} x {image_height}, and each side must be at most {MAX_IMAGE_SIDE} pixels")


def png_size_from_header(png_bytes):
    """(width, height) from a PNG's IHDR chunk, or None for bytes that do not start like a PNG. Nothing is decoded."""
    if len(png_bytes) < 24 or not png_bytes.startswith(PNG_SIGNATURE) or png_bytes[12:16] != b"IHDR":
        return None
    return int.from_bytes(png_bytes[16:20], "big"), int.from_bytes(png_bytes[20:24], "big")


def parse_plane_request(body):
    """Checks the body and returns (frame_rgb, person_mask or None, anchor, focal_hint or None)."""
    if not isinstance(body, dict):
        raise BadRequestError("The body must be a JSON object")
    try:
        # Only JPEG is allowed: Pillow opens any format it has a plugin for, and some (EPS with Ghostscript installed) run
        # other programs. The mask is read by OpenCV after its PNG header is checked, so Pillow never sees it.
        frame_image = Image.open(io.BytesIO(decode_base64(body.get("jpegBase64"), "jpegBase64")), formats=["JPEG"])
        # `size` comes from the header, so a file that declares a huge image is refused before its pixels are decoded.
        refuse_an_image_over_the_side_limit("jpegBase64", *frame_image.size)
        frame_rgb = np.array(frame_image.convert("RGB"))
    except Image.DecompressionBombError:
        # Pillow's own guard for an image of many times this limit, which it refuses while opening.
        raise BadRequestError(f"jpegBase64 spans far more than {MAX_IMAGE_SIDE} x {MAX_IMAGE_SIDE} pixels")
    except (UnidentifiedImageError, OSError):
        raise BadRequestError("jpegBase64 is not a readable JPEG")
    image_height, image_width = frame_rgb.shape[:2]

    anchor = body.get("anchor")
    anchor_is_valid = (
        isinstance(anchor, dict)
        and all(isinstance(anchor.get(axis), (int, float)) and not isinstance(anchor.get(axis), bool) for axis in ("u", "v"))
    )
    if not anchor_is_valid:
        raise BadRequestError("anchor must be an object with numbers u and v")
    if not (0 <= anchor["u"] < image_width and 0 <= anchor["v"] < image_height):
        raise BadRequestError(f"anchor must lie inside the {image_width} x {image_height} frame")

    focal_hint = body.get("focalPx")
    if focal_hint is not None and (isinstance(focal_hint, bool) or not isinstance(focal_hint, (int, float)) or not focal_hint > 0):
        raise BadRequestError("focalPx must be a positive number")

    person_mask = None
    if body.get("maskPngBase64") is not None:
        mask_bytes = decode_base64(body["maskPngBase64"], "maskPngBase64")
        mask_size = png_size_from_header(mask_bytes)
        if mask_size is None:
            raise BadRequestError("maskPngBase64 is not a readable PNG")
        refuse_an_image_over_the_side_limit("maskPngBase64", *mask_size)
        mask_small = cv2.imdecode(np.frombuffer(mask_bytes, np.uint8), cv2.IMREAD_GRAYSCALE)
        if mask_small is None:
            raise BadRequestError("maskPngBase64 is not a readable PNG")
        person_mask = cv2.resize(mask_small, (image_width, image_height)) > PERSON_MASK_THRESHOLD
    return frame_rgb, person_mask, anchor, focal_hint


# Each route runs the one Depth Pro path (`infer_depth`, one lock) and then its own geometry.
GEOMETRY_BY_ROUTE = {"/wall": plane.wall_frame, "/floor": plane.floor_frame}


def measure_plane(route, body):
    started_at = time.time()
    frame_rgb, person_mask, anchor, focal_hint = parse_plane_request(body)
    depth_m, focal_px, depth_was_cached = cached_depth(depth_cache_key(body["jpegBase64"], focal_hint), frame_rgb, focal_hint)
    inference_seconds = time.time() - started_at
    frame = GEOMETRY_BY_ROUTE[route](depth_m, focal_px, person_mask, anchor)
    return {
        **frame,
        "depthWasCached": depth_was_cached,
        "inferenceSeconds": round(inference_seconds, 2),
        "seconds": round(time.time() - started_at, 2),
    }


def refusal_for_headers(headers):
    """(status, error) for a request a web page could have sent, or None.

    A browser adds an Origin header to every cross-site POST, and a page can send
    a simple POST with no preflight only as form or plain text, so refusing both
    keeps any page in a browser on this Mac from spending Depth Pro runs. The
    Worker sends application/json and no Origin.
    """
    if headers.get("Origin") is not None:
        return 403, "Requests from web pages are refused"
    content_type = (headers.get("Content-Type") or "").split(";")[0].strip().lower()
    if content_type != "application/json":
        return 415, "The body must be application/json"
    return None


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, payload):
        encoded = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if self.path == "/health":
            self.reply(200, {"ok": True})
        else:
            self.reply(404, {"error": "Not found"})

    def do_POST(self):
        route = self.path
        if route not in GEOMETRY_BY_ROUTE:
            self.reply(404, {"error": "Not found"})
            return
        refusal = refusal_for_headers(self.headers)
        if refusal is not None:
            status, error = refusal
            print(f"[{route}] {status} {error}", flush=True)
            self.reply(status, {"error": error})
            return
        started_at = time.time()
        try:
            content_length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self.reply(400, {"error": "Content-Length is required"})
            return
        if not 0 < content_length <= MAX_BODY_BYTES:
            self.reply(400, {"error": f"The body must be 1 to {MAX_BODY_BYTES} bytes"})
            return
        try:
            body = json.loads(self.rfile.read(content_length))
            result, status = measure_plane(route, body), 200
        except (json.JSONDecodeError, UnicodeDecodeError):
            result, status = {"error": "The body is not valid JSON"}, 400
        except BadRequestError as error:
            result, status = {"error": str(error)}, 400
        except plane.PlaneNotMeasuredError as error:
            result, status = {"error": str(error)}, 422
        except Exception as error:  # a model or geometry failure: log it and answer 500
            print(f"[{route}] failed: {error!r}", flush=True)
            result, status = {"error": f"{type(error).__name__}: {error}"}, 500
        self.reply(status, result)
        if status == 200:
            angle_name, angle = ("angle", result.get("wallAngleDegrees")) if route == "/wall" else ("tilt", result.get("floorTiltDegrees"))
            print(
                f"[{route}] 200 distance={result['distanceMeters']} m {angle_name}={angle} deg "
                f"inliers={result['planeInlierShare']} focal={result['focalPx']} px "
                f"inference={result['inferenceSeconds']} s total={result['seconds']} s cached={result['depthWasCached']}",
                flush=True,
            )
        else:
            print(f"[{route}] {status} {result['error']} ({time.time() - started_at:.2f} s)", flush=True)

    def log_message(self, format, *args):
        pass  # do_POST logs one line per request


def main():
    checkpoint_path = os.environ.get("DEPTH_PRO_CHECKPOINT", DEFAULT_CHECKPOINT_PATH)
    if not os.path.isfile(checkpoint_path):
        sys.exit(f"The Depth Pro checkpoint is missing at {checkpoint_path}.\nDownload it (1.9 GB) from {CHECKPOINT_DOWNLOAD_URL}")
    port = int(os.environ.get("DEPTH_SERVICE_PORT", DEFAULT_PORT))
    load_depth_pro(checkpoint_path)
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    print(f"Depth service listening on http://127.0.0.1:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
