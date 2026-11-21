#!/usr/bin/env python3
"""Checks that every image the AppIcon set names exists at its exact pixel size, with an alpha channel.

A size mismatch makes Xcode warn and macOS scale the icon blurry, and a missing alpha channel
brings back the black square behind the rounded corners.

Run:  python3 -I tools/app-icon/check-app-icon.py
"""

import json
import struct
import sys
from pathlib import Path

APP_ICON_SET_DIRECTORY = (
    Path(__file__).resolve().parents[2] / "leanring-buddy/Assets.xcassets/AppIcon.appiconset"
)
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
RGBA_COLOR_TYPE = 6


def png_width_height_and_color_type(path: Path) -> tuple[int, int, int]:
    header = path.read_bytes()[:26]
    if not header.startswith(PNG_SIGNATURE):
        raise ValueError(f"{path.name} is not a PNG")
    width, height = struct.unpack(">II", header[16:24])
    return width, height, header[25]


def main() -> int:
    contents = json.loads((APP_ICON_SET_DIRECTORY / "Contents.json").read_text())
    problems = []
    for image in contents["images"]:
        points = int(image["size"].split("x")[0])
        expected_pixels = points * int(image["scale"].rstrip("x"))
        path = APP_ICON_SET_DIRECTORY / image["filename"]
        width, height, color_type = png_width_height_and_color_type(path)
        if (width, height) != (expected_pixels, expected_pixels):
            problems.append(f"{path.name} is {width}x{height}, {image['size']}@{image['scale']} needs {expected_pixels}")
        if color_type != RGBA_COLOR_TYPE:
            problems.append(f"{path.name} has no alpha channel")
        if image["idiom"] != "mac":
            problems.append(f"{path.name} has idiom {image['idiom']}, this is a Mac-only app")
    for problem in problems:
        print(problem)
    print("app icon set OK" if not problems else f"{len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
