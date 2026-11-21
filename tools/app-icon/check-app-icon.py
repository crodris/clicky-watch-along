#!/usr/bin/env python3
"""Checks every image the AppIcon set names: it exists, has its exact pixel size, and has the icon's alpha shape.

A size mismatch makes Xcode warn and macOS scale the icon blurry. Opaque corners bring back the black
square behind the rounded tile, which is what this icon replaced, so the four corners must be transparent
and the center opaque.

Run:  python3 -I tools/app-icon/check-app-icon.py
"""

import json
import struct
import sys
import zlib
from pathlib import Path

APP_ICON_SET_DIRECTORY = (
    Path(__file__).resolve().parents[2] / "leanring-buddy/Assets.xcassets/AppIcon.appiconset"
)
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
EIGHT_BIT_RGBA = (8, 6)
BYTES_PER_PIXEL = 4


def paeth_predictor(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    distance_left = abs(estimate - left)
    distance_above = abs(estimate - above)
    distance_upper_left = abs(estimate - upper_left)
    if distance_left <= distance_above and distance_left <= distance_upper_left:
        return left
    return above if distance_above <= distance_upper_left else upper_left


def decode_rgba_rows(png_bytes: bytes) -> tuple[int, int, list[bytearray]]:
    """Decodes an 8-bit RGBA, non-interlaced PNG into its rows. Raises ValueError for any other PNG."""
    if not png_bytes.startswith(PNG_SIGNATURE):
        raise ValueError("not a PNG")
    width = height = 0
    compressed = b""
    position = len(PNG_SIGNATURE)
    while position < len(png_bytes):
        (length,) = struct.unpack(">I", png_bytes[position : position + 4])
        chunk_type = png_bytes[position + 4 : position + 8]
        chunk = png_bytes[position + 8 : position + 8 + length]
        position += 12 + length
        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
            if (bit_depth, color_type) != EIGHT_BIT_RGBA or interlace != 0:
                raise ValueError("not an 8-bit RGBA PNG without interlacing, so it has no alpha channel to check")
        elif chunk_type == b"IDAT":
            compressed += chunk
    raw = zlib.decompress(compressed)
    stride = width * BYTES_PER_PIXEL
    rows: list[bytearray] = []
    previous = bytearray(stride)
    for row_index in range(height):
        start = row_index * (stride + 1)
        filter_type = raw[start]
        row = bytearray(raw[start + 1 : start + 1 + stride])
        for index in range(stride):
            left = row[index - BYTES_PER_PIXEL] if index >= BYTES_PER_PIXEL else 0
            above = previous[index]
            upper_left = previous[index - BYTES_PER_PIXEL] if index >= BYTES_PER_PIXEL else 0
            if filter_type == 1:
                row[index] = (row[index] + left) & 255
            elif filter_type == 2:
                row[index] = (row[index] + above) & 255
            elif filter_type == 3:
                row[index] = (row[index] + (left + above) // 2) & 255
            elif filter_type == 4:
                row[index] = (row[index] + paeth_predictor(left, above, upper_left)) & 255
        rows.append(row)
        previous = row
    return width, height, rows


def alpha_at(rows: list[bytearray], horizontal_position: int, vertical_position: int) -> int:
    return rows[vertical_position][horizontal_position * BYTES_PER_PIXEL + 3]


def problems_with_image(path: Path, expected_pixels: int) -> list[str]:
    try:
        width, height, rows = decode_rgba_rows(path.read_bytes())
    except (OSError, ValueError, zlib.error, struct.error) as error:
        return [f"{path.name}: {error}"]
    problems = []
    if (width, height) != (expected_pixels, expected_pixels):
        problems.append(f"{path.name} is {width}x{height} and needs {expected_pixels}x{expected_pixels}")
        return problems
    last = expected_pixels - 1
    for corner_name, corner in {"top left": (0, 0), "top right": (last, 0), "bottom left": (0, last), "bottom right": (last, last)}.items():
        if alpha_at(rows, *corner) != 0:
            problems.append(f"{path.name} has an opaque {corner_name} corner, so macOS shows a square behind the icon")
    if alpha_at(rows, expected_pixels // 2, expected_pixels // 2) != 255:
        problems.append(f"{path.name} is not opaque at its center")
    return problems


def main() -> int:
    contents = json.loads((APP_ICON_SET_DIRECTORY / "Contents.json").read_text())
    problems = []
    for image in contents["images"]:
        label = f"{image['size']}@{image['scale']}"
        if image["idiom"] != "mac":
            problems.append(f"{label} has idiom {image['idiom']}, and this is a Mac-only app")
        filename = image.get("filename")
        if filename is None:
            problems.append(f"{label} names no file")
            continue
        points = int(image["size"].split("x")[0])
        expected_pixels = points * int(image["scale"].rstrip("x"))
        problems += problems_with_image(APP_ICON_SET_DIRECTORY / filename, expected_pixels)
    for problem in problems:
        print(problem)
    print("app icon set OK" if not problems else f"{len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
