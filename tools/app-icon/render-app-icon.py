#!/usr/bin/env python3
"""Draws Clicky's app icon and renders every size the AppIcon set needs.

The icon is the cursor inside the ring of 24 ticks the app draws around it while the
learner talks, on a deep blue rounded square.

Run from anywhere:  python3 -I tools/app-icon/render-app-icon.py

It writes two things from one set of shapes, so they cannot differ:
  - leanring-buddy/AppIcon.icon   the Icon Composer file, which gives the icon its dark,
                                  tinted, and clear modes: the field as the icon's gradient
                                  fill, and the ticks and the cursor as layers on a full 1024
                                  point canvas. The tile shadow and the cursor's shadow are
                                  left out, since Icon Composer draws its own.
  - leanring-buddy/Assets.xcassets/AppIcon.appiconset/*-mac.png   the sizes macOS before 26 uses

Rasterizing uses headless Google Chrome, since it draws SVG gradients and filters
exactly and needs no Python packages. Pass --icon-file-only to skip the PNGs.
"""

import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
ICON_COMPOSER_FILE = REPOSITORY_ROOT / "leanring-buddy/AppIcon.icon"
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
LARGEST_SIMPLE_ART_PIXEL_SIZE = 32


def squircle_path_data() -> str:
    center = CANVAS / 2
    radius = TILE_SIZE / 2
    point_count = 360
    points = []
    for step in range(point_count):
        angle = 2 * math.pi * step / point_count
        cosine, sine = math.cos(angle), math.sin(angle)
        horizontal_position = center + radius * math.copysign(abs(cosine) ** (2 / SQUIRCLE_EXPONENT), cosine)
        vertical_position = center + radius * math.copysign(abs(sine) ** (2 / SQUIRCLE_EXPONENT), sine)
        points.append(f"{horizontal_position:.2f} {vertical_position:.2f}")
    return "M" + " L".join(points) + " Z"


SQUIRCLE = squircle_path_data()

FIELD_TOP_COLOR = "#2f6dff"
FIELD_BOTTOM_COLOR = "#0f2a7a"

FIELD_LAYER = f"""\
<defs>
  <linearGradient id="field-gradient" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="{FIELD_TOP_COLOR}"/><stop offset="1" stop-color="{FIELD_BOTTOM_COLOR}"/>
  </linearGradient>
  <radialGradient id="field-glow" cx=".3" cy=".2" r=".9">
    <stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset="1" stop-color="#fff" stop-opacity="0"/>
  </radialGradient>
</defs>
<path d="{SQUIRCLE}" fill="url(#field-gradient)"/>
<path d="{SQUIRCLE}" fill="url(#field-glow)"/>"""

# The listening ring (`CursorRingGeometry` in the app): 24 ticks that start a fixed distance from the cursor and grow
# outward, here frozen at the lengths of one spoken word, longer and brighter where the voice is louder.
RING_CENTER = 512
TICK_START_RADIUS = 262
TICK_LENGTHS = [41, 63, 94, 124, 101, 76, 54, 41, 58, 99, 135, 112, 81, 59, 45, 40, 54, 86, 119, 97, 70, 50, 40, 43]
LONGEST_TICK = max(TICK_LENGTHS)


def tick_line(tick_index: int, tick_length: float) -> str:
    # The first tick points straight up, and the ticks go clockwise 15 degrees apart.
    angle = math.radians(tick_index * 360 / len(TICK_LENGTHS) - 90)
    start_x = RING_CENTER + TICK_START_RADIUS * math.cos(angle)
    start_y = RING_CENTER + TICK_START_RADIUS * math.sin(angle)
    end_x = RING_CENTER + (TICK_START_RADIUS + tick_length) * math.cos(angle)
    end_y = RING_CENTER + (TICK_START_RADIUS + tick_length) * math.sin(angle)
    opacity = 0.55 + 0.45 * tick_length / LONGEST_TICK
    return (
        f'<line x1="{start_x:.1f}" y1="{start_y:.1f}" x2="{end_x:.1f}" y2="{end_y:.1f}" '
        f'stroke="#fff" stroke-width="24" stroke-linecap="round" opacity="{opacity:.2f}"/>'
    )


TICKS_LAYER = "\n".join(tick_line(tick_index, tick_length) for tick_index, tick_length in enumerate(TICK_LENGTHS))

# The cursor points up and to the left, at the app's pointer angle: the app draws its tip straight up and turns it
# 35 degrees to the left. Here the tip lies along +x, so the same direction is a turn of -125 degrees (90 + 35).
CURSOR_ROTATION_DEGREES = -125
CURSOR_CENTER_X = 512
CURSOR_CENTER_Y = 520
CURSOR_SCALE = 1.05
# The icon's cursor is a notched dart, not the app's equilateral triangle: a pale equilateral triangle on its own
# reads as a play button at any angle, and the notch gives it one clear tip. Its tip lies along +x.
CURSOR_PATH = "M170 0 L -95 120 L -40 0 L -95 -120 Z"
CURSOR_OUTLINE = "M-95 -120 L170 0 L -95 120"
# Three motion streaks trail behind the notch, as a school's volleyball draws in flight, so the cursor reads as moving
# toward its tip.
CURSOR_STREAKS = [(-70, 39), (0, 61), (70, 39)]
CURSOR_TRANSFORM = f"translate({CURSOR_CENTER_X} {CURSOR_CENTER_Y}) rotate({CURSOR_ROTATION_DEGREES}) scale({CURSOR_SCALE})"


def streak_line(vertical_offset: int, streak_length: int) -> str:
    return (
        f'<line x1="-75" y1="{vertical_offset}" x2="{-75 - streak_length}" y2="{vertical_offset}" '
        f'stroke="#fff" stroke-width="15" stroke-linecap="round" opacity=".55"/>'
    )


# The cursor is shaded bright at its tip and deep at its base, as the app's cursor is, with a light edge on the two
# sides that meet at the tip.
CURSOR_LAYER = f"""\
<defs>
  <linearGradient id="cursor-gradient" x1="1" y1=".5" x2="0" y2=".5">
    <stop offset="0" stop-color="#fff"/><stop offset=".4" stop-color="#e3edff"/><stop offset="1" stop-color="#7ea4ff"/>
  </linearGradient>
</defs>
<g transform="{CURSOR_TRANSFORM}">
  {"".join(streak_line(vertical_offset, streak_length) for vertical_offset, streak_length in CURSOR_STREAKS)}
  <path d="{CURSOR_PATH}" fill="url(#cursor-gradient)"/>
  <path d="{CURSOR_OUTLINE}" fill="none" stroke="#fff" stroke-width="9" stroke-linejoin="round" opacity=".95"/>
</g>"""

# The cursor's own shadow stays out of the Icon Composer layers: Icon Composer adds its own shadow, and in its
# tinted and clear modes a drawn one would show as a second cursor. It is drawn into the PNGs only.
# Its offset sits outside the turn, so the shadow falls down and to the right whatever way the cursor points.
CURSOR_SHADOW = f"""\
<g transform="translate({CURSOR_CENTER_X + 13} {CURSOR_CENTER_Y + 23}) rotate({CURSOR_ROTATION_DEGREES}) scale({CURSOR_SCALE})">
  <path d="{CURSOR_PATH}" fill="#06123a" opacity=".38"/>
</g>"""

# At 32 pixels and below the ticks turn to texture, so only a large white cursor stays. The dart's middle sits 37.5
# points toward its tip from its origin, so the origin moves that far back along the tip's direction to center it.
SIMPLE_CURSOR_SCALE = 1.6
SIMPLE_CURSOR_CENTER_X = 512 + 37.5 * SIMPLE_CURSOR_SCALE * -math.cos(math.radians(CURSOR_ROTATION_DEGREES))
SIMPLE_CURSOR_CENTER_Y = 512 + 37.5 * SIMPLE_CURSOR_SCALE * -math.sin(math.radians(CURSOR_ROTATION_DEGREES))
SIMPLE_CURSOR_LAYER = f"""\
<g transform="translate({SIMPLE_CURSOR_CENTER_X:.1f} {SIMPLE_CURSOR_CENTER_Y:.1f}) rotate({CURSOR_ROTATION_DEGREES}) scale({SIMPLE_CURSOR_SCALE})">
  <path d="{CURSOR_PATH}" fill="#fff"/>
</g>"""

SHADOW_FILTER = f"""\
<defs>
  <filter id="tile-shadow" x="-10%" y="-10%" width="120%" height="125%">
    <feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#000" flood-opacity=".3"/>
  </filter>
</defs>
<path d="{SQUIRCLE}" fill="{FIELD_BOTTOM_COLOR}" filter="url(#tile-shadow)"/>"""


def svg_document(inner_markup: str, pixel_size: int = CANVAS) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{pixel_size}" height="{pixel_size}" '
        f'viewBox="0 0 {CANVAS} {CANVAS}">\n{inner_markup}\n</svg>\n'
    )


def icon_composer_color(hex_color: str) -> str:
    red, green, blue = (int(hex_color[index : index + 2], 16) / 255 for index in (1, 3, 5))
    return f"srgb:{red:.5f},{green:.5f},{blue:.5f},1.00000"


def write_icon_composer_file() -> None:
    """Writes AppIcon.icon as Icon Composer saves it: icon.json and the layer files in Assets."""
    assets_directory = ICON_COMPOSER_FILE / "Assets"
    assets_directory.mkdir(parents=True, exist_ok=True)
    # Icon Composer lists a group's layers front first.
    layers = {"cursor": CURSOR_LAYER, "ticks": TICKS_LAYER}
    for stale_asset in assets_directory.iterdir():
        if stale_asset.stem not in layers:
            stale_asset.unlink()
    for layer_name, markup in layers.items():
        (assets_directory / f"{layer_name}.svg").write_text(svg_document(markup))
    icon_description = {
        "fill": {
            "linear-gradient": [icon_composer_color(FIELD_TOP_COLOR), icon_composer_color(FIELD_BOTTOM_COLOR)],
            "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}},
        },
        "groups": [
            {
                "layers": [{"image-name": f"{layer_name}.svg", "name": layer_name} for layer_name in layers],
                "shadow": {"kind": "neutral", "opacity": 0.5},
                "translucency": {"enabled": True, "value": 0.5},
            }
        ],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }
    (ICON_COMPOSER_FILE / "icon.json").write_text(json.dumps(icon_description, indent=2) + "\n")


def icon_markup(pixel_size: int) -> str:
    if pixel_size <= LARGEST_SIMPLE_ART_PIXEL_SIZE:
        return "\n".join([FIELD_LAYER, SIMPLE_CURSOR_LAYER])
    return "\n".join([SHADOW_FILTER, FIELD_LAYER, TICKS_LAYER, CURSOR_SHADOW, CURSOR_LAYER])


def render_png(pixel_size: int, destination: Path) -> None:
    if not Path(CHROME_EXECUTABLE).exists():
        sys.exit(f"Google Chrome is needed to rasterize the icon, and {CHROME_EXECUTABLE} does not exist.")
    # A stale file must not pass for a fresh render when Chrome exits without writing one.
    destination.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory() as working_directory:
        page = Path(working_directory) / "icon.html"
        page.write_text(
            "<!doctype html><meta charset=utf-8>"
            "<style>html,body{margin:0;background:transparent}svg{display:block}</style>"
            + svg_document(icon_markup(pixel_size), pixel_size)
        )
        chrome_run = subprocess.run(
            [
                CHROME_EXECUTABLE,
                "--headless=new",
                "--disable-gpu",
                "--hide-scrollbars",
                # The hex colors are sRGB, so the render must not pick up the display's profile.
                "--force-color-profile=srgb",
                "--force-device-scale-factor=1",
                "--default-background-color=00000000",
                f"--window-size={pixel_size},{pixel_size}",
                f"--screenshot={destination}",
                page.as_uri(),
            ],
            capture_output=True,
            text=True,
        )
    if chrome_run.returncode != 0 or not destination.exists():
        sys.exit(f"Chrome did not render {destination.name} (exit {chrome_run.returncode}):\n{chrome_run.stderr}")


def main() -> None:
    write_icon_composer_file()
    if "--icon-file-only" in sys.argv:
        return
    for pixel_size in RENDERED_PIXEL_SIZES:
        render_png(pixel_size, APP_ICON_SET_DIRECTORY / f"{pixel_size}-mac.png")


if __name__ == "__main__":
    main()
