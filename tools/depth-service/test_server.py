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
from test_plane import FLOOR_ANCHOR, FOCAL_PX, FRAME_H, FRAME_W, floor_depth, noisy_wall_depth  # noqa: F401


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
    [("/wall", plane.NonFinitePlaneError), ("/floor", plane.NonFinitePlaneError), ("/floor", plane.NotFloorLikeError), ("/floor", plane.TooLittleFloorError)],
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


def test_wall_route_keeps_its_reply_and_a_wall_sent_to_floor_is_a_plane_not_measured_error(monkeypatch, noisy_wall_depth):
    monkeypatch.setattr(server, "infer_depth", lambda frame_rgb, focal_hint: (noisy_wall_depth, FOCAL_PX))
    body = frame_body({"u": 960, "v": 540})

    wall_reply = server.measure_plane("/wall", body)
    assert {"center", "right", "up", "wallAngleDegrees"} <= wall_reply.keys()
    assert "forward" not in wall_reply
    with pytest.raises(plane.PlaneNotMeasuredError):
        server.measure_plane("/floor", body)
