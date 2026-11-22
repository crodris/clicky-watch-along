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
    vs, us = np.mgrid[0:FRAME_H, 0:FRAME_W]
    return np.stack([(us - FRAME_W / 2) / FOCAL_PX, (vs - FRAME_H / 2) / FOCAL_PX, np.ones((FRAME_H, FRAME_W))], axis=-1)


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


def test_ransac_on_42000_points_runs_under_half_a_second():
    # 42,000 points of a tilted plane: the 4,000 point subset path.
    vs, us = np.mgrid[0:200, 0:210]
    depths = plane_depth(WALL_NORMAL)[vs * 5, us * 9]
    points = plane.back_project(us.ravel().astype(float) * 9, vs.ravel().astype(float) * 5, depths.ravel(), FOCAL_PX, (FRAME_W / 2, FRAME_H / 2))
    assert len(points) == 42_000

    started_at = time.perf_counter()
    normal, _, inlier_share = plane.fit_plane_ransac(points, inlier_distance_m=0.02)
    seconds = time.perf_counter() - started_at

    assert seconds < 0.5
    assert angle_between_degrees(normal, WALL_NORMAL) < 0.1
    assert inlier_share > 0.99


def test_a_plane_with_a_nan_raises_instead_of_writing_nan(noisy_wall_depth, monkeypatch):
    # A fit that comes back with a NaN normal, as a wall seen edge on can.
    monkeypatch.setattr(plane, "fit_plane_ransac", lambda points, inlier_distance_m: (np.array([np.nan, 0.0, -1.0]), np.array([0.0, 0.0, 3.0]), 0.9))

    with pytest.raises(plane.NonFinitePlaneError):
        plane.wall_frame(noisy_wall_depth, FOCAL_PX, None, ANCHOR)
