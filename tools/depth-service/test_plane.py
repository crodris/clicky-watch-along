import time

import numpy as np
import pytest

import plane

FRAME_W, FRAME_H = 1920, 1080
FOCAL_PX = 1500.0
ANCHOR = {"u": 960, "v": 540}
# Faces the camera and tilts about 17 degrees to the left and 6 degrees up.
WALL_NORMAL = np.array([0.3, -0.1, -1.0]) / np.linalg.norm([0.3, -0.1, -1.0])


def pixel_rays():
    pixel_vs, pixel_us = np.mgrid[0:FRAME_H, 0:FRAME_W]
    return np.stack([(pixel_us - FRAME_W / 2) / FOCAL_PX, (pixel_vs - FRAME_H / 2) / FOCAL_PX, np.ones((FRAME_H, FRAME_W))], axis=-1)


def plane_depth(normal, distance_along_z=3.0):
    """Depth in meters of a plane through (0, 0, distance_along_z) with the given normal."""
    offset = normal @ np.array([0.0, 0.0, distance_along_z])
    return offset / (pixel_rays() @ normal)


def wall_normal_from(frame):
    return np.cross(frame["right"], frame["up"])


def angle_between_degrees(first_normal, second_normal):
    cosine = abs(first_normal @ second_normal) / (np.linalg.norm(first_normal) * np.linalg.norm(second_normal))
    return float(np.degrees(np.arccos(min(1.0, cosine))))


@pytest.fixture
def noisy_wall_depth():
    depth = plane_depth(WALL_NORMAL)
    depth += np.random.default_rng(3).normal(0, 0.005, depth.shape)
    return depth


def test_tilted_wall_with_noise_and_an_object_in_front_recovers_the_normal(noisy_wall_depth):
    # A 200 x 200 pixel object 40 cm in front of the wall, inside the sampled window.
    noisy_wall_depth[440:640, 860:1060] -= 0.4
    frame = plane.wall_frame(noisy_wall_depth, FOCAL_PX, None, ANCHOR)

    assert angle_between_degrees(wall_normal_from(frame), WALL_NORMAL) < 1.0
    assert frame["planeInlierShare"] > 0.8
    # The object was not part of the plane: the wall at the anchor is 3 m away along z.
    assert abs(frame["distanceMeters"] - 3.0) < 0.1


def test_right_is_level_and_up_points_up_in_the_image(noisy_wall_depth):
    frame = plane.wall_frame(noisy_wall_depth, FOCAL_PX, None, ANCHOR)

    assert frame["right"][0] > 0
    assert frame["up"][1] < 0
    assert abs(frame["right"][1]) < 1e-4
    assert abs(np.dot(frame["right"], frame["up"])) < 1e-4


def test_person_mask_removes_points_that_would_win_the_plane_fit(noisy_wall_depth):
    # A person covers the left 60% of the sampled window, standing in a flat plane 1.5 m away.
    person_mask = np.zeros((FRAME_H, FRAME_W), bool)
    person_mask[:, 653:1022] = True
    noisy_wall_depth[person_mask] = 1.5

    without_mask = plane.wall_frame(noisy_wall_depth, FOCAL_PX, None, ANCHOR)
    with_mask = plane.wall_frame(noisy_wall_depth, FOCAL_PX, person_mask, ANCHOR)

    assert angle_between_degrees(wall_normal_from(without_mask), WALL_NORMAL) > 5.0
    assert angle_between_degrees(wall_normal_from(with_mask), WALL_NORMAL) < 1.0


def test_too_little_bare_wall_raises(noisy_wall_depth):
    person_mask = np.ones((FRAME_H, FRAME_W), bool)
    person_mask[540, 960] = False

    with pytest.raises(plane.TooLittleWallError):
        plane.wall_frame(noisy_wall_depth, FOCAL_PX, person_mask, ANCHOR)


def test_center_lies_on_the_ray_through_the_anchor_and_on_the_wall(noisy_wall_depth):
    anchor = {"u": 700, "v": 400}
    frame = plane.wall_frame(noisy_wall_depth, FOCAL_PX, None, anchor)

    center = np.array(frame["center"])
    expected_ray = np.array([(anchor["u"] - FRAME_W / 2) / FOCAL_PX, (anchor["v"] - FRAME_H / 2) / FOCAL_PX, 1.0])
    assert np.allclose(center / center[2], expected_ray, atol=1e-3)
    wall_offset = WALL_NORMAL @ np.array([0.0, 0.0, 3.0])
    assert abs(WALL_NORMAL @ center - wall_offset) < 0.02
    assert frame["principal"] == [FRAME_W / 2, FRAME_H / 2]
    assert frame["focalPx"] == FOCAL_PX


def test_ransac_on_42000_points_runs_under_two_seconds():
    # 42,000 points of a tilted plane: the 4,000 point subset path.
    grid_vs, grid_us = np.mgrid[0:200, 0:210]
    depths = plane_depth(WALL_NORMAL)[grid_vs * 5, grid_us * 9]
    points = plane.back_project(grid_us.ravel().astype(float) * 9, grid_vs.ravel().astype(float) * 5, depths.ravel(), FOCAL_PX, (FRAME_W / 2, FRAME_H / 2))
    assert len(points) == 42_000

    started_at = time.perf_counter()
    normal, _, inlier_share = plane.fit_plane_ransac(points, inlier_distance_m=0.02)
    seconds = time.perf_counter() - started_at

    # About 0.35 s on a quiet Mac. The bound is 2 s so a loaded machine does not fail it, and it still catches the BLAS
    # product that took 40 ms per iteration, 16 s in all.
    assert seconds < 2.0
    assert angle_between_degrees(normal, WALL_NORMAL) < 0.1
    assert inlier_share > 0.99


def test_a_plane_with_a_nan_raises_instead_of_writing_nan(noisy_wall_depth, monkeypatch):
    # A fit that comes back with a NaN normal, as a wall seen edge on can.
    monkeypatch.setattr(plane, "fit_plane_ransac", lambda points, inlier_distance_m: (np.array([np.nan, 0.0, -1.0]), np.array([0.0, 0.0, 3.0]), 0.9))

    with pytest.raises(plane.NonFinitePlaneError):
        plane.wall_frame(noisy_wall_depth, FOCAL_PX, None, ANCHOR)


# The floor: a camera 1.2 m high, pitched 15 degrees down. In the camera's frame (x right,
# y down, z forward) the world's up direction is (0, -cos, -sin), since a camera looking down sees the sky behind its view axis, and the floor is the plane
# whose points p have up . p = -1.2.
CAMERA_HEIGHT_M = 1.2
CAMERA_PITCH_DEGREES = 15.0
FLOOR_UP = np.array([0.0, -np.cos(np.radians(CAMERA_PITCH_DEGREES)), -np.sin(np.radians(CAMERA_PITCH_DEGREES))])
FLOOR_ANCHOR = {"u": 960, "v": 700}


def floor_depth():
    """Depth of the floor at each pixel, with 5 mm of noise. Pixels above the horizon get 50 m."""
    rays_dot_up = pixel_rays() @ FLOOR_UP
    depth = np.where(rays_dot_up < -1e-3, -CAMERA_HEIGHT_M / np.minimum(rays_dot_up, -1e-3), 50.0)
    return depth + np.random.default_rng(5).normal(0, 0.005, depth.shape)


def test_floor_seen_from_a_camera_pitched_down_recovers_up_and_puts_center_on_the_anchor_ray():
    frame = plane.floor_frame(floor_depth(), FOCAL_PX, None, FLOOR_ANCHOR)

    assert angle_between_degrees(np.array(frame["up"]), FLOOR_UP) < 2.0
    assert frame["up"][1] < 0
    assert abs(frame["floorTiltDegrees"] - CAMERA_PITCH_DEGREES) < 2.0
    center = np.array(frame["center"])
    expected_ray = np.array([(FLOOR_ANCHOR["u"] - FRAME_W / 2) / FOCAL_PX, (FLOOR_ANCHOR["v"] - FRAME_H / 2) / FOCAL_PX, 1.0])
    assert np.allclose(center / center[2], expected_ray, atol=1e-3)
    # The center is on the floor: 1.2 m below the camera along the floor normal.
    assert abs(FLOOR_UP @ center + CAMERA_HEIGHT_M) < 0.03
    assert frame["planeInlierShare"] > 0.8


def test_floor_frame_axes_are_orthonormal_with_forward_away_from_the_camera():
    frame = plane.floor_frame(floor_depth(), FOCAL_PX, None, FLOOR_ANCHOR)
    right, up, forward = (np.array(frame[name]) for name in ("right", "up", "forward"))

    assert right[0] > 0.99
    assert forward[2] > 0.9
    assert np.allclose(forward, np.cross(up, right), atol=1e-4)
    # right x up points toward the camera, the opposite of forward.
    assert np.allclose(np.cross(right, up), -forward, atol=1e-4)
    for first, second in ((right, up), (right, forward), (up, forward)):
        assert abs(first @ second) < 1e-4
    assert abs(np.linalg.norm(forward) - 1.0) < 1e-4
    # A step along forward stays on the floor plane.
    step = np.array(frame["center"]) + forward
    assert abs(FLOOR_UP @ step + CAMERA_HEIGHT_M) < 0.03


def test_a_wall_like_plane_is_not_a_floor(noisy_wall_depth):
    with pytest.raises(plane.NotFloorLikeError):
        plane.floor_frame(noisy_wall_depth, FOCAL_PX, None, ANCHOR)


def test_an_anchor_above_the_horizon_is_not_a_floor():
    # Pitched down 15 degrees, the horizon is at v = 540 - 1500 * tan(15 degrees) = 138.
    with pytest.raises(plane.NotFloorLikeError):
        plane.floor_frame(floor_depth(), FOCAL_PX, None, {"u": 960, "v": 60})


def test_floor_person_mask_removes_points_that_would_win_the_plane_fit():
    depth = floor_depth()
    # A person covers 78% of the sampled window, a flat plane 2 m away.
    person_mask = np.zeros((FRAME_H, FRAME_W), bool)
    person_mask[:, 600:1200] = True
    depth[person_mask] = 2.0

    with pytest.raises(plane.NotFloorLikeError):
        plane.floor_frame(depth, FOCAL_PX, None, FLOOR_ANCHOR)
    frame = plane.floor_frame(depth, FOCAL_PX, person_mask, FLOOR_ANCHOR)

    assert angle_between_degrees(np.array(frame["up"]), FLOOR_UP) < 2.0


def test_too_little_bare_floor_raises():
    person_mask = np.ones((FRAME_H, FRAME_W), bool)
    person_mask[700, 960] = False

    with pytest.raises(plane.TooLittleFloorError):
        plane.floor_frame(floor_depth(), FOCAL_PX, person_mask, FLOOR_ANCHOR)


def test_a_floor_plane_with_a_nan_raises_instead_of_writing_nan(monkeypatch):
    monkeypatch.setattr(plane, "fit_plane_ransac", lambda points, inlier_distance_m: (np.array([np.nan, -1.0, 0.0]), np.array([0.0, 1.2, 3.0]), 0.9))

    with pytest.raises(plane.NonFinitePlaneError):
        plane.floor_frame(floor_depth(), FOCAL_PX, None, FLOOR_ANCHOR)


def test_floor_inliers_tolerate_the_depth_noise_of_a_floor_seen_at_a_grazing_angle():
    # 3 cm of depth noise on top of the fixture's 5 mm: 96% of the points lie within the floor's 3 cm inlier distance,
    # where the wall's 2 cm would count only 84%.
    depth = floor_depth() + np.random.default_rng(9).normal(0, 0.03, (FRAME_H, FRAME_W))

    frame = plane.floor_frame(depth, FOCAL_PX, None, FLOOR_ANCHOR)

    assert frame["planeInlierShare"] > 0.93
    assert angle_between_degrees(np.array(frame["up"]), FLOOR_UP) < 2.0
