#!/usr/bin/env python3
"""Draws Clicky's app icon and renders every size the AppIcon set needs.

The icon is the cursor arriving along a dotted arc into its landing ring
(the Tether spec's "Point" move), on a deep blue rounded square.

Run from anywhere:  python3 -I tools/app-icon/render-app-icon.py

It writes two things from one set of shapes, so they cannot differ:
  - tools/app-icon/layers/*.svg   the four layers (field, arc, ring, cursor), each a
                                  full 1024 point canvas, to import into Icon Composer
  - leanring-buddy/Assets.xcassets/AppIcon.appiconset/*-mac.png   the shipped sizes

Rasterizing uses headless Google Chrome, since it draws SVG gradients and filters
exactly and needs no Python packages. Pass --layers-only to skip the PNGs.
"""

import math
import subprocess
import sys
import tempfile
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
LAYERS_DIRECTORY = Path(__file__).resolve().parent / "layers"
APP_ICON_SET_DIRECTORY = REPOSITORY_ROOT / "leanring-buddy/Assets.xcassets/AppIcon.appiconset"
CHROME_EXECUTABLE = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

CANVAS = 1024
# macOS app icons fill 824 of the 1024 canvas, leaving a margin for the shadow.
TILE_INSET = 100
TILE_SIZE = CANVAS - 2 * TILE_INSET
# Apple's icon shape is a superellipse, not a plain rounded rectangle. Exponent 5 matches it closely.
SQUIRCLE_EXPONENT = 5

# Pixel sizes of the files the AppIcon set refers to, and the sizes that use the simple art.
RENDERED_PIXEL_SIZES = [16, 32, 64, 128, 256, 512, 1024]
LARGEST_SIMPLE_ART_PIXEL_SIZE = 64


def squircle_path_data() -> str:
    center = CANVAS / 2
    radius = TILE_SIZE / 2
    point_count = 360
    points = []
    for step in range(point_count):
        angle = 2 * math.pi * step / point_count
        cosine, sine = math.cos(angle), math.sin(angle)
        x = center + radius * math.copysign(abs(cosine) ** (2 / SQUIRCLE_EXPONENT), cosine)
        y = center + radius * math.copysign(abs(sine) ** (2 / SQUIRCLE_EXPONENT), sine)
        points.append(f"{x:.2f} {y:.2f}")
    return "M" + " L".join(points) + " Z"


SQUIRCLE = squircle_path_data()

FIELD_LAYER = f"""\
<defs>
  <linearGradient id="field-gradient" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#2f6dff"/><stop offset="1" stop-color="#0f2a7a"/>
  </linearGradient>
  <radialGradient id="field-glow" cx=".3" cy=".2" r=".9">
    <stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset="1" stop-color="#fff" stop-opacity="0"/>
  </radialGradient>
</defs>
<path d="{SQUIRCLE}" fill="url(#field-gradient)"/>
<path d="{SQUIRCLE}" fill="url(#field-glow)"/>"""

ARC_LAYER = """\
<path d="M240 740 Q 400 300 650 420" fill="none" stroke="#fff" stroke-width="18"
      stroke-linecap="round" stroke-dasharray="2 46" opacity=".8"/>
<circle cx="240" cy="740" r="16" fill="#fff" opacity=".8"/>"""

RING_LAYER = """\
<circle cx="668" cy="430" r="150" fill="none" stroke="#9cc0ff" stroke-width="14" opacity=".75"/>"""

CURSOR_LAYER = """\
<defs>
  <linearGradient id="cursor-gradient" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#cfe0ff"/>
  </linearGradient>
</defs>
<g transform="translate(650 420) rotate(-35)">
  <path d="M-95 -120 L 150 0 L -95 120 Z" fill="#0a1a4a" opacity=".35" transform="translate(10 22)"/>
  <path d="M-95 -120 L 150 0 L -95 120 Z" fill="url(#cursor-gradient)"/>
  <path d="M-95 -120 L 150 0" stroke="#fff" stroke-width="10" opacity=".9"/>
</g>"""

# At 64 pixels and below the arc and ring turn to mush, so only a large white cursor stays.
SIMPLE_CURSOR_LAYER = """\
<g transform="translate(560 512) rotate(-35)">
  <path d="M-170 -210 L 250 0 L -170 210 Z" fill="#fff"/>
</g>"""

SHADOW_FILTER = f"""\
<defs>
  <filter id="tile-shadow" x="-10%" y="-10%" width="120%" height="125%">
    <feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#000" flood-opacity=".3"/>
  </filter>
</defs>
<path d="{SQUIRCLE}" fill="#0f2a7a" filter="url(#tile-shadow)"/>"""


def svg_document(inner_markup: str, pixel_size: int = CANVAS) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{pixel_size}" height="{pixel_size}" '
        f'viewBox="0 0 {CANVAS} {CANVAS}">\n{inner_markup}\n</svg>\n'
    )


def write_layers() -> None:
    LAYERS_DIRECTORY.mkdir(exist_ok=True)
    layers = {
        "1-field": FIELD_LAYER,
        "2-arc": ARC_LAYER,
        "3-ring": RING_LAYER,
        "4-cursor": CURSOR_LAYER,
    }
    for layer_name, markup in layers.items():
        (LAYERS_DIRECTORY / f"{layer_name}.svg").write_text(svg_document(markup))


def icon_markup(pixel_size: int) -> str:
    if pixel_size <= LARGEST_SIMPLE_ART_PIXEL_SIZE:
        return "\n".join([FIELD_LAYER, SIMPLE_CURSOR_LAYER])
    return "\n".join([SHADOW_FILTER, FIELD_LAYER, ARC_LAYER, RING_LAYER, CURSOR_LAYER])


def render_png(pixel_size: int, destination: Path) -> None:
    with tempfile.TemporaryDirectory() as working_directory:
        page = Path(working_directory) / "icon.html"
        page.write_text(
            "<!doctype html><meta charset=utf-8>"
            "<style>html,body{margin:0;background:transparent}svg{display:block}</style>"
            + svg_document(icon_markup(pixel_size), pixel_size)
        )
        subprocess.run(
            [
                CHROME_EXECUTABLE,
                "--headless=new",
                "--disable-gpu",
                "--hide-scrollbars",
                "--force-device-scale-factor=1",
                "--default-background-color=00000000",
                f"--window-size={pixel_size},{pixel_size}",
                f"--screenshot={destination}",
                page.as_uri(),
            ],
            check=True,
            capture_output=True,
        )


def main() -> None:
    write_layers()
    if "--layers-only" in sys.argv:
        return
    for pixel_size in RENDERED_PIXEL_SIZES:
        render_png(pixel_size, APP_ICON_SET_DIRECTORY / f"{pixel_size}-mac.png")


if __name__ == "__main__":
    main()
