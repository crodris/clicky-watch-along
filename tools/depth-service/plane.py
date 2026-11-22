"""The wall geometry, with no torch import so its tests run in a second.

A depth map and a focal length turn a patch of pixels into 3D points in the
camera's frame (x right, y down, z forward, in meters). A RANSAC plane fit on
the bare wall points gives the wall's plane, and `wall_frame` turns the plane
into a placement frame at the anchor pixel: a center, and a right and an up
direction that lie on the wall and keep the artwork level with the camera.
"""

import numpy as np

# Wall points come from a square around the anchor, this share of the frame's width on each side.
WALL_WINDOW_HALF_SHARE = 0.16
# Every third pixel in each direction gives enough points and keeps the fit fast.
WALL_SAMPLE_STEP_PIXELS = 3
MINIMUM_BARE_WALL_POINTS = 200
WALL_INLIER_DISTANCE_M = 0.02


class WallNotMeasuredError(ValueError):
    """The photo was read, and it holds no wall the artwork can hang on. The server answers 422."""


class TooLittleWallError(WallNotMeasuredError):
    """Fewer than MINIMUM_BARE_WALL_POINTS pixels around the anchor are free of people."""


class NonFinitePlaneError(WallNotMeasuredError):
    """The fitted plane has a NaN or infinite number, such as a wall seen edge on, so it places nothing."""


def back_project(pixel_us, pixel_vs, depths, focal_px, principal_point):
    principal_u, principal_v = principal_point
    xs = (pixel_us - principal_u) * depths / focal_px
    ys = (pixel_vs - principal_v) * depths / focal_px
    return np.stack([xs, ys, depths], axis=1)


def plane_distances(points, point_on_plane, normal):
    # Element by element: in a process that has loaded torch, NumPy's BLAS
    # matrix product took 40 ms for this N x 3 by 3 product instead of microseconds.
    return np.abs(
        (points[:, 0] - point_on_plane[0]) * normal[0]
        + (points[:, 1] - point_on_plane[1]) * normal[1]
        + (points[:, 2] - point_on_plane[2]) * normal[2]
    )


def fit_plane_ransac(points, iterations=400, inlier_distance_m=0.015, seed=7, ransac_sample_size=4000):
    """Returns (unit normal facing the camera, a point on the plane, the share of points within the distance)."""
    random_generator = np.random.default_rng(seed)
    # RANSAC on a random subset finds the plane as well as on every point.
    subset = points[random_generator.choice(len(points), min(len(points), ransac_sample_size), replace=False)]
    best_plane, best_count = None, -1
    for _ in range(iterations):
        sample = subset[random_generator.choice(len(subset), 3, replace=False)]
        normal = np.cross(sample[1] - sample[0], sample[2] - sample[0])
        normal_length = np.linalg.norm(normal)
        if normal_length < 1e-9:
            continue
        normal /= normal_length
        count = int((plane_distances(subset, sample[0], normal) < inlier_distance_m).sum())
        if count > best_count:
            best_plane, best_count = (sample[0], normal), count
    if best_plane is None:
        raise ValueError("No plane fits these points")
    best_inliers = plane_distances(points, *best_plane) < inlier_distance_m
    inlier_points = points[best_inliers]
    centroid = inlier_points.mean(axis=0)
    # Least squares refinement: the normal is the smallest singular vector.
    # full_matrices=False: the default builds an N x N matrix (14 GB for 42,000
    # points) that only the left singular vectors need.
    _, _, right_singular_vectors = np.linalg.svd(inlier_points - centroid, full_matrices=False)
    normal = right_singular_vectors[2]
    if normal[2] > 0:  # face the camera
        normal = -normal
    return normal, centroid, best_inliers.mean()


def wall_frame(depth_m, focal_px, person_mask, anchor):
    """Measures the wall around `anchor`, a dict with `u` and `v` in the frame's pixels.

    `depth_m` is the depth map in meters at the frame's size. `person_mask` is a
    boolean array of the same size, True where a person is, or None. The principal
    point is the frame's center. Raises TooLittleWallError when under 200 bare wall
    points remain around the anchor, and NonFinitePlaneError when the plane has a
    NaN or infinite number.
    """
    image_height, image_width = depth_m.shape
    anchor_u, anchor_v = float(anchor["u"]), float(anchor["v"])
    window_half_width = int(WALL_WINDOW_HALF_SHARE * image_width)
    window_left = max(0, int(anchor_u) - window_half_width)
    window_right = min(image_width, int(anchor_u) + window_half_width)
    window_top = max(0, int(anchor_v) - window_half_width)
    window_bottom = min(image_height, int(anchor_v) + window_half_width)
    grid_vs, grid_us = np.mgrid[window_top:window_bottom:WALL_SAMPLE_STEP_PIXELS, window_left:window_right:WALL_SAMPLE_STEP_PIXELS]
    if person_mask is None:
        keep = np.ones(grid_vs.shape, bool)
    else:
        keep = ~person_mask[grid_vs, grid_us]
    us, vs = grid_us[keep].astype(np.float64), grid_vs[keep].astype(np.float64)
    if len(us) < MINIMUM_BARE_WALL_POINTS:
        raise TooLittleWallError("Too little bare wall around that point: click away from people and objects")

    principal = (image_width / 2, image_height / 2)
    points = back_project(us, vs, depth_m[vs.astype(int), us.astype(int)], focal_px, principal)
    normal, plane_point, inlier_share = fit_plane_ransac(points, inlier_distance_m=WALL_INLIER_DISTANCE_M)

    ray = np.array([(anchor_u - principal[0]) / focal_px, (anchor_v - principal[1]) / focal_px, 1.0])
    center = ray * ((plane_point @ normal) / (ray @ normal))
    # Keep the artwork level: its horizontal edge is perpendicular to both the
    # wall normal and the camera's up direction.
    camera_up = np.array([0.0, -1.0, 0.0])
    right = np.cross(camera_up, normal)
    right /= np.linalg.norm(right)
    if right[0] < 0:
        right = -right
    up = np.cross(normal, right)
    if up[1] > 0:
        up = -up
    # A NaN or inf would reach the app as JSON it cannot read, or hang the art nowhere, so it is a wall not measured.
    numbers = np.concatenate([center, right, up, [focal_px, inlier_share]])
    if not np.all(np.isfinite(numbers)):
        raise NonFinitePlaneError("The wall's plane could not be measured there: point the camera straight at a bare wall")
    return {
        "center": center.round(4).tolist(),
        "right": right.round(5).tolist(),
        "up": up.round(5).tolist(),
        "focalPx": round(float(focal_px), 2),
        "principal": [principal[0], principal[1]],
        "distanceMeters": round(float(np.linalg.norm(center)), 3),
        "wallAngleDegrees": round(float(np.degrees(np.arccos(abs(normal[2])))), 1),
        "planeInlierShare": round(float(inlier_share), 3),
    }
