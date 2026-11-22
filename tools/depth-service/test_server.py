"""The /wall endpoint's refusals, through a real HTTP server on a free port, with no Depth Pro loaded."""

import http.client
import json
import threading
from http.server import ThreadingHTTPServer

import pytest

import plane
import server


@pytest.fixture
def depth_service_port():
    http_server = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
    server_thread = threading.Thread(target=http_server.serve_forever, daemon=True)
    server_thread.start()
    yield http_server.server_address[1]
    http_server.shutdown()
    http_server.server_close()


def post_wall(port, headers, body=b'{"jpegBase64": "AAAA", "anchor": {"u": 1, "v": 1}}'):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.request("POST", "/wall", body=body, headers={"Content-Length": str(len(body)), **headers})
    response = connection.getresponse()
    reply = (response.status, json.loads(response.read()))
    connection.close()
    return reply


def test_a_request_with_an_origin_header_is_refused_with_403(depth_service_port):
    status, reply = post_wall(depth_service_port, {"Content-Type": "application/json", "Origin": "https://shop.example"})

    assert status == 403
    assert reply == {"error": "Requests from web pages are refused"}


@pytest.mark.parametrize("content_type", [None, "text/plain", "application/x-www-form-urlencoded", "multipart/form-data"])
def test_a_body_that_is_not_application_json_is_refused_with_415(depth_service_port, content_type):
    headers = {} if content_type is None else {"Content-Type": content_type}

    status, reply = post_wall(depth_service_port, headers)

    assert status == 415
    assert reply == {"error": "The body must be application/json"}


def test_a_wall_that_cannot_be_measured_answers_422(depth_service_port, monkeypatch):
    # The Worker's own request: application/json with a charset and no Origin reaches the measurement.
    def measure_a_wall_seen_edge_on(body):
        raise plane.NonFinitePlaneError("The wall's plane could not be measured there")

    monkeypatch.setattr(server, "measure_wall", measure_a_wall_seen_edge_on)

    status, reply = post_wall(depth_service_port, {"Content-Type": "application/json; charset=utf-8"})

    assert status == 422
    assert reply == {"error": "The wall's plane could not be measured there"}
