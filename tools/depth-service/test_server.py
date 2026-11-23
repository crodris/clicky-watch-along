"""The /wall and /floor endpoints: the refusals through a real HTTP server on a free port, and each
route's reply through the real measurement code with a stand-in for Depth Pro (none is loaded)."""

import base64
import http.client
import io
import json
import threading
from http.server import ThreadingHTTPServer

import numpy as np
import pytest
from PIL import Image

import plane
import server
from test_plane import (  # noqa: F401
    FLOOR_ANCHOR,
    FOCAL_PX,
    FRAME_H,
    FRAME_W,
    TABLE_TOP_ANCHOR,
    floor_depth,
    noisy_wall_depth,
    table_top_in_front_of_a_wall_depth,
)


@pytest.fixture(autouse=True)
def an_empty_depth_cache(monkeypatch):
    # Every test sends the same gray JPEG, so a depth kept by one test would answer the next.
    monkeypatch.setattr(server, "depth_cache", server.collections.OrderedDict())


@pytest.fixture
def depth_service_port():
    http_server = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
    server_thread = threading.Thread(target=http_server.serve_forever, daemon=True)
    server_thread.start()
    yield http_server.server_address[1]
    http_server.shutdown()
    http_server.server_close()


def post_to_route(port, route, headers, body=b'{"jpegBase64": "AAAA", "anchor": {"u": 1, "v": 1}}'):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.request("POST", route, body=body, headers={"Content-Length": str(len(body)), **headers})
    response = connection.getresponse()
    reply = (response.status, json.loads(response.read()))
    connection.close()
    return reply


def frame_body(anchor):
    buffer = io.BytesIO()
    Image.fromarray(np.full((FRAME_H, FRAME_W, 3), 128, np.uint8)).save(buffer, "JPEG")
    return {"jpegBase64": base64.b64encode(buffer.getvalue()).decode(), "anchor": anchor}


@pytest.mark.parametrize("route", ["/wall", "/floor"])
def test_a_request_with_an_origin_header_is_refused_with_403(depth_service_port, route):
    status, reply = post_to_route(depth_service_port, route, {"Content-Type": "application/json", "Origin": "https://shop.example"})

    assert status == 403
    assert reply == {"error": "Requests from web pages are refused"}


@pytest.mark.parametrize("route", ["/wall", "/floor"])
@pytest.mark.parametrize("content_type", [None, "text/plain", "application/x-www-form-urlencoded", "multipart/form-data"])
def test_a_body_that_is_not_application_json_is_refused_with_415(depth_service_port, route, content_type):
    headers = {} if content_type is None else {"Content-Type": content_type}

    status, reply = post_to_route(depth_service_port, route, headers)

    assert status == 415
    assert reply == {"error": "The body must be application/json"}


@pytest.mark.parametrize(
    "route, error_class",
    [
        ("/wall", plane.NonFinitePlaneError),
        ("/floor", plane.NonFinitePlaneError),
        ("/floor", plane.NotFloorLikeError),
        ("/floor", plane.TooLittleFloorError),
        ("/floor", plane.NotLevelSurfaceError),
        ("/floor", plane.TooLittleSurfaceError),
    ],
)
def test_a_plane_that_cannot_be_measured_answers_422(depth_service_port, monkeypatch, route, error_class):
    # The Worker's own request: application/json with a charset and no Origin reaches the measurement.
    def measure_a_plane_that_cannot_be_placed(requested_route, body):
        raise error_class("The plane could not be measured there")

    monkeypatch.setattr(server, "measure_plane", measure_a_plane_that_cannot_be_placed)

    status, reply = post_to_route(depth_service_port, route, {"Content-Type": "application/json; charset=utf-8"})

    assert status == 422
    assert reply == {"error": "The plane could not be measured there"}


def test_an_unknown_route_answers_404(depth_service_port):
    status, _ = post_to_route(depth_service_port, "/ceiling", {"Content-Type": "application/json"})

    assert status == 404


def test_floor_route_returns_the_frame_with_forward_and_timings(monkeypatch):
    monkeypatch.setattr(server, "infer_depth", lambda frame_rgb, focal_hint: (floor_depth(), FOCAL_PX))

    reply = server.measure_plane("/floor", frame_body(FLOOR_ANCHOR))

    assert {"center", "right", "up", "forward", "floorTiltDegrees", "inferenceSeconds", "seconds"} <= reply.keys()
    assert "wallAngleDegrees" not in reply


def test_floor_route_with_stands_on_table_or_shelf_measures_the_table_top_the_floor_fit_misses(monkeypatch):
    monkeypatch.setattr(server, "infer_depth", lambda frame_rgb, focal_hint: (table_top_in_front_of_a_wall_depth(), FOCAL_PX))
    body = frame_body(TABLE_TOP_ANCHOR)

    with pytest.raises(plane.NotFloorLikeError):
        server.measure_plane("/floor", body)
    with pytest.raises(plane.NotFloorLikeError):
        server.measure_plane("/floor", {**body, "standsOn": "floor"})
    reply = server.measure_plane("/floor", {**body, "standsOn": "tableOrShelf"})

    assert reply["floorTiltDegrees"] < 20
    assert reply["planeInlierShare"] > 0.4


@pytest.mark.parametrize("stands_on", ["table", "", 3, True, ["floor"]])
def test_an_unknown_stands_on_is_a_400_before_any_depth_run(monkeypatch, stands_on):
    monkeypatch.setattr(server, "infer_depth", lambda frame_rgb, focal_hint: pytest.fail("Depth Pro must not run for a bad body"))

    with pytest.raises(server.BadRequestError, match="standsOn"):
        server.measure_plane("/floor", {**frame_body(FLOOR_ANCHOR), "standsOn": stands_on})


def test_stands_on_is_refused_on_the_wall_route():
    with pytest.raises(server.BadRequestError, match="only for /floor"):
        server.parse_stands_on("/wall", {"standsOn": "floor"})


def test_a_bad_stands_on_answers_400_through_the_handler(depth_service_port):
    body = json.dumps({"jpegBase64": "AAAA", "anchor": {"u": 1, "v": 1}, "standsOn": "ceiling"}).encode()

    status, reply = post_to_route(depth_service_port, "/floor", {"Content-Type": "application/json"}, body)

    assert status == 400
    assert "jpegBase64" in reply["error"] or "standsOn" in reply["error"]


def test_wall_route_keeps_its_reply_and_a_wall_sent_to_floor_is_a_plane_not_measured_error(monkeypatch, noisy_wall_depth):
    monkeypatch.setattr(server, "infer_depth", lambda frame_rgb, focal_hint: (noisy_wall_depth, FOCAL_PX))
    body = frame_body({"u": 960, "v": 540})

    wall_reply = server.measure_plane("/wall", body)
    assert {"center", "right", "up", "wallAngleDegrees"} <= wall_reply.keys()
    assert "forward" not in wall_reply
    with pytest.raises(plane.PlaneNotMeasuredError):
        server.measure_plane("/floor", body)


def test_a_second_measurement_of_the_same_frame_reuses_its_depth(monkeypatch):
    depth_runs = []

    def count_the_depth_runs(frame_rgb, focal_hint):
        depth_runs.append(focal_hint)
        return floor_depth(), FOCAL_PX

    monkeypatch.setattr(server, "infer_depth", count_the_depth_runs)
    body = frame_body(FLOOR_ANCHOR)

    first_reply = server.measure_plane("/floor", body)
    second_reply = server.measure_plane("/floor", body)

    assert len(depth_runs) == 1
    assert (first_reply["depthWasCached"], second_reply["depthWasCached"]) == (False, True)
    assert first_reply["center"] == second_reply["center"]


def test_the_cache_keeps_only_the_newest_frames(monkeypatch):
    depth_runs = []

    def count_the_depth_runs(frame_rgb, focal_hint):
        depth_runs.append(focal_hint)
        return floor_depth(), FOCAL_PX

    monkeypatch.setattr(server, "infer_depth", count_the_depth_runs)
    bodies = [{**frame_body(FLOOR_ANCHOR), "focalPx": focal} for focal in (900, 1000, 1100)]

    for body in bodies:
        server.measure_plane("/floor", body)
    server.measure_plane("/floor", bodies[0])

    assert depth_runs == [900, 1000, 1100, 900]
    assert len(server.depth_cache) == server.DEPTH_CACHE_SIZE


def png_bytes_of_size(width, height):
    buffer = io.BytesIO()
    Image.fromarray(np.zeros((height, width), np.uint8)).save(buffer, "PNG")
    return buffer.getvalue()


def a_png_header_that_declares(width, height):
    """The first 24 bytes of a PNG that states a size its image data never holds, as a hostile file would."""
    ihdr_fields = width.to_bytes(4, "big") + height.to_bytes(4, "big")
    return server.PNG_SIGNATURE + (13).to_bytes(4, "big") + b"IHDR" + ihdr_fields


def base64_of(data):
    return base64.b64encode(data).decode()


def test_an_image_over_4096_pixels_on_a_side_is_refused_before_its_pixels_are_decoded():
    buffer = io.BytesIO()
    Image.fromarray(np.full((8, server.MAX_IMAGE_SIDE + 1, 3), 128, np.uint8)).save(buffer, "JPEG")
    body = {"jpegBase64": base64_of(buffer.getvalue()), "anchor": {"u": 1, "v": 1}}

    with pytest.raises(server.BadRequestError, match=r"jpegBase64 is 4097 x 8, and each side must be at most 4096"):
        server.parse_plane_request(body)


def test_a_frame_that_is_not_a_jpeg_is_refused_with_400(depth_service_port):
    # A PNG is a readable image, but only a JPEG frame is accepted, since Pillow opens any format it has a plugin for.
    body = {**frame_body({"u": 1, "v": 1}), "jpegBase64": base64_of(png_bytes_of_size(32, 18))}

    with pytest.raises(server.BadRequestError, match="jpegBase64 is not a readable JPEG"):
        server.parse_plane_request(body)

    status, reply = post_to_route(depth_service_port, "/wall", {"Content-Type": "application/json"}, json.dumps(body).encode())
    assert status == 400
    assert reply == {"error": "jpegBase64 is not a readable JPEG"}


def test_an_image_at_the_side_limit_is_read():
    buffer = io.BytesIO()
    Image.fromarray(np.full((8, server.MAX_IMAGE_SIDE, 3), 128, np.uint8)).save(buffer, "JPEG")
    body = {"jpegBase64": base64_of(buffer.getvalue()), "anchor": {"u": 1, "v": 1}}

    frame_rgb, _, _, _ = server.parse_plane_request(body)

    assert frame_rgb.shape == (8, server.MAX_IMAGE_SIDE, 3)


def test_a_mask_over_4096_pixels_on_a_side_is_refused_before_it_is_decoded(monkeypatch):
    # A forged header with no image data behind it: the refusal must come from the header, since decoding would fail or
    # allocate the size it states.
    def never_decode_the_mask(*arguments, **keyword_arguments):
        raise AssertionError("the mask was decoded")

    monkeypatch.setattr(server.cv2, "imdecode", never_decode_the_mask)
    body = {**frame_body({"u": 1, "v": 1}), "maskPngBase64": base64_of(a_png_header_that_declares(60_000, 60_000))}

    with pytest.raises(server.BadRequestError, match=r"maskPngBase64 is 60000 x 60000, and each side must be at most 4096"):
        server.parse_plane_request(body)


def test_a_mask_that_is_not_a_png_is_refused_without_a_decode(monkeypatch):
    monkeypatch.setattr(server.cv2, "imdecode", lambda *arguments, **keyword_arguments: pytest.fail("the mask was decoded"))
    body = {**frame_body({"u": 1, "v": 1}), "maskPngBase64": base64_of(b"GIF89a not a PNG at all, and long enough")}

    with pytest.raises(server.BadRequestError, match="maskPngBase64 is not a readable PNG"):
        server.parse_plane_request(body)


def test_a_mask_within_the_limit_is_scaled_to_the_frame():
    body = {**frame_body({"u": 1, "v": 1}), "maskPngBase64": base64_of(png_bytes_of_size(32, 18))}

    frame_rgb, person_mask, _, _ = server.parse_plane_request(body)

    assert person_mask.shape == frame_rgb.shape[:2]


@pytest.mark.parametrize("route", ["/wall", "/floor"])
def test_a_refusal_is_logged_under_the_route_that_was_called(depth_service_port, capsys, route):
    post_to_route(depth_service_port, route, {"Content-Type": "application/json", "Origin": "https://shop.example"})

    logged_lines = capsys.readouterr().out.splitlines()

    assert f"[{route}] 403 Requests from web pages are refused" in logged_lines
