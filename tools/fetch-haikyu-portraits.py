#!/usr/bin/env python3
"""Fetch the round anime portraits for the optional Haikyu!! team theme.

Usage:
    python3 -I tools/fetch-haikyu-portraits.py [--themes-dir themes]
                                               [--output-dir leanring-buddy/HaikyuPortraits]
                                               [--force]

The rosters in the bundled theme files (themes/*.clickytheme/theme.json) are the
single source of truth: each player's `fullName` names a page on
haikyuu.fandom.com, and its `portrait` names the file. This script downloads each
page's main image and crops it to a 160x160 JPEG with that file name. The
portraits are anime art, so the output folder is gitignored and the images never
reach the public repository. Xcode copies the folder to the top of the app's
Resources, where the app looks a bundled roster's portraits up.

Requires python3 (standard library only) and ffmpeg on PATH.
"""

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_THEMES_DIRECTORY = REPOSITORY_ROOT / "themes"
DEFAULT_OUTPUT_DIRECTORY = REPOSITORY_ROOT / "leanring-buddy" / "HaikyuPortraits"

WIKI_API_URL = "https://haikyuu.fandom.com/api.php"
REQUEST_USER_AGENT = "Mozilla/5.0 (Macintosh)"
REQUEST_TIMEOUT_SECONDS = 30
PORTRAIT_PIXEL_SIZE = 160

# Share of the leftover height that is cropped away from the top. A small share keeps the head.
DEFAULT_CROP_TOP_SHARE = 0.12

# Pages whose default crop misses the face. Each entry scales the image to a larger square first
# (so the face fills the 160 pixel frame), then crops 160x160 at the given shares of the leftover
# height and width. A face off to one side, as in an action shot, sets a left share other than 0.5.
# fullName: (square size in pixels, share of leftover height cropped from the top[, share of leftover width cropped from the left])
FACE_CROP_OVERRIDES = {
    "Kanji Koganegawa": (330, 0.10),
    "Takanobu Aone": (280, 0.12),
    "Hajime Iwaizumi": (250, 0.02),
    "Tōru Oikawa": (250, 0.05),
    "Hitoshi Ginjima": (440, 0.13),
    "Ren Ōmimi": (440, 0.085),
    "Michinari Akagi": (420, 0.11),
    "Yū Nishinoya": (300, 0.16, 0.36),
}



def read_roster_portraits(themes_directory: Path) -> list[tuple[str, str]]:
    """Return (full name, portrait file name) for every roster player of every bundled theme, in file order."""
    roster_portraits = []
    for theme_file in sorted(themes_directory.glob("*.clickytheme/theme.json")):
        faces = json.loads(theme_file.read_text(encoding="utf-8")).get("agents", {}).get("faces", {})
        if faces.get("kind") != "roster":
            continue
        for player in faces.get("players", []):
            portrait_file_name = player.get("portrait")
            # A portrait name is joined onto the output folder, so one with a folder in it is refused.
            if not portrait_file_name or "/" in portrait_file_name or portrait_file_name.startswith("."):
                continue
            entry = (player.get("fullName") or player["name"], portrait_file_name)
            if entry not in roster_portraits:
                roster_portraits.append(entry)
    return roster_portraits


# The wiki's API names the image URL, so only its own image host over https is fetched, and no reply is read past
# this size.
PORTRAIT_IMAGE_HOST = "static.wikia.nocookie.net"
MOST_REPLY_BYTES = 8 * 1024 * 1024


class SameHostRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Follow a redirect only to https on the host the request went to, so a checked URL cannot hop elsewhere."""

    def redirect_request(self, request, response_file, code, message, headers, new_url):
        original_host = urllib.parse.urlparse(request.full_url).hostname
        parsed_new_url = urllib.parse.urlparse(new_url)
        if parsed_new_url.scheme != "https" or parsed_new_url.hostname != original_host:
            raise RuntimeError(f"refused a redirect from {request.full_url} to {new_url}")
        return super().redirect_request(request, response_file, code, message, headers, new_url)


URL_OPENER = urllib.request.build_opener(SameHostRedirectHandler)

# The image formats the wiki serves, by their first bytes. ffmpeg guesses a format from the bytes it gets, so anything
# else, such as a playlist that names other files, is refused before ffmpeg sees it.
IMAGE_FILE_SIGNATURES = (b"\x89PNG\r\n\x1a\n", b"\xff\xd8\xff", b"GIF87a", b"GIF89a")


def is_an_image(image_bytes: bytes) -> bool:
    is_webp = image_bytes[:4] == b"RIFF" and image_bytes[8:12] == b"WEBP"
    return is_webp or image_bytes.startswith(IMAGE_FILE_SIGNATURES)


def open_url(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": REQUEST_USER_AGENT})
    with URL_OPENER.open(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
        reply_bytes = response.read(MOST_REPLY_BYTES + 1)
    if len(reply_bytes) > MOST_REPLY_BYTES:
        raise RuntimeError(f"the reply from {url} is over {MOST_REPLY_BYTES} bytes")
    return reply_bytes


def checked_image_url(image_url: str) -> str:
    parsed_image_url = urllib.parse.urlparse(image_url)
    if parsed_image_url.scheme != "https" or parsed_image_url.hostname != PORTRAIT_IMAGE_HOST:
        raise RuntimeError(f"the page image is not on https://{PORTRAIT_IMAGE_HOST}: {image_url}")
    return image_url


def page_image_url(wiki_title: str) -> str:
    query = urllib.parse.urlencode(
        {
            "action": "query",
            "prop": "pageimages",
            "piprop": "thumbnail|original",
            "pithumbsize": "600",
            "redirects": "1",
            "format": "json",
            "titles": wiki_title,
        }
    )
    reply = json.loads(open_url(f"{WIKI_API_URL}?{query}"))
    for page in reply.get("query", {}).get("pages", {}).values():
        image = page.get("thumbnail") or page.get("original")
        if image:
            return image["source"]
    raise RuntimeError("the wiki page has no page image")


def crop_filter(wiki_title: str) -> str:
    override = FACE_CROP_OVERRIDES.get(wiki_title)
    if override is None:
        square_size, crop_top_share, crop_left_share = PORTRAIT_PIXEL_SIZE, DEFAULT_CROP_TOP_SHARE, 0.5
    else:
        square_size, crop_top_share = override[0], override[1]
        crop_left_share = override[2] if len(override) > 2 else 0.5
    return (
        f"scale={square_size}:{square_size}:force_original_aspect_ratio=increase,"
        f"crop={PORTRAIT_PIXEL_SIZE}:{PORTRAIT_PIXEL_SIZE}:"
        f"(iw-{PORTRAIT_PIXEL_SIZE})*{crop_left_share}:(ih-{PORTRAIT_PIXEL_SIZE})*{crop_top_share}"
    )


def download_portrait(wiki_title: str, output_file: Path) -> None:
    image_bytes = open_url(checked_image_url(page_image_url(wiki_title)))
    if not is_an_image(image_bytes):
        raise RuntimeError("the page image is not a PNG, JPEG, GIF, or WebP file")
    # ffmpeg writes into the temporary folder, and the result replaces the portrait only on success, so a failed or
    # interrupted --force run keeps the portrait that was there and leaves nothing in the bundled folder.
    with tempfile.TemporaryDirectory() as temporary_directory:
        downloaded_file = Path(temporary_directory) / "download"
        partial_output_file = Path(temporary_directory) / "portrait.jpg"
        downloaded_file.write_bytes(image_bytes)
        result = subprocess.run(
            [
                "ffmpeg", "-nostdin", "-loglevel", "error", "-y",
                # The download is untrusted, so ffmpeg may open only that local file, never a URL a playlist names.
                "-protocol_whitelist", "file",
                "-i", str(downloaded_file),
                "-vf", crop_filter(wiki_title),
                "-frames:v", "1", "-q:v", "3",
                str(partial_output_file),
            ],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(f"ffmpeg failed: {result.stderr.strip()}")
        shutil.move(partial_output_file, output_file)


def main() -> int:
    argument_parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    argument_parser.add_argument("--themes-dir", type=Path, default=DEFAULT_THEMES_DIRECTORY)
    argument_parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIRECTORY)
    argument_parser.add_argument("--force", action="store_true", help="re-download files that already exist")
    arguments = argument_parser.parse_args()

    if shutil.which("ffmpeg") is None:
        print("ffmpeg is not on PATH", file=sys.stderr)
        return 1

    roster_portraits = read_roster_portraits(arguments.themes_dir)
    if not roster_portraits:
        print(f"no roster portraits found in {arguments.themes_dir}", file=sys.stderr)
        return 1

    arguments.output_dir.mkdir(parents=True, exist_ok=True)
    failed_titles = []
    for wiki_title, portrait_file_name in roster_portraits:
        output_file = arguments.output_dir / portrait_file_name
        if output_file.exists() and not arguments.force:
            print(f"skipped    {wiki_title} ({output_file.name} exists)")
            continue
        try:
            download_portrait(wiki_title, output_file)
            print(f"downloaded {wiki_title} -> {output_file.name}")
        except Exception as error:
            failed_titles.append(wiki_title)
            print(f"FAILED     {wiki_title}: {error}", file=sys.stderr)

    if failed_titles:
        print(f"{len(failed_titles)} of {len(roster_portraits)} portraits failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
