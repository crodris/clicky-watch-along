#!/usr/bin/env python3
"""Fetch the round anime portraits for the optional Haikyu!! team theme.

Usage:
    python3 -I tools/fetch-haikyu-portraits.py [--swift-file leanring-buddy/HaikyuTheme.swift]
                                               [--output-dir leanring-buddy/HaikyuPortraits]
                                               [--force]

The roster table in HaikyuTheme.swift is the single source of truth: every
`wikiTitle: "..."` string in it names a page on haikyuu.fandom.com. This script
downloads each page's main image and crops it to a 160x160 JPEG named
`<portraitResourceName>.jpg`, where the resource name is "haikyu-" plus the ASCII
slug of the wiki title (diacritics stripped, lowercased, runs of non-alphanumerics
become "-"). The portraits are anime art, so the output folder is gitignored and
the images never reach the public repository.

Requires python3 (standard library only) and ffmpeg on PATH.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
import urllib.parse
import urllib.request
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SWIFT_FILE = REPOSITORY_ROOT / "leanring-buddy" / "HaikyuTheme.swift"
DEFAULT_OUTPUT_DIRECTORY = REPOSITORY_ROOT / "leanring-buddy" / "HaikyuPortraits"

WIKI_API_URL = "https://haikyuu.fandom.com/api.php"
REQUEST_USER_AGENT = "Mozilla/5.0 (Macintosh)"
REQUEST_TIMEOUT_SECONDS = 30
PORTRAIT_PIXEL_SIZE = 160

# Share of the leftover height that is cropped away from the top. A small share keeps the head.
DEFAULT_CROP_TOP_SHARE = 0.12

# Pages whose default crop misses the face. Each entry scales the image to a larger square first
# (so the face fills the 160 pixel frame), then crops 160x160 from the horizontal center at the
# given share of the leftover height.
# wikiTitle: (square size in pixels, share of leftover height cropped from the top)
FACE_CROP_OVERRIDES = {
    "Kanji Koganegawa": (330, 0.10),
    "Takanobu Aone": (280, 0.12),
    "Hajime Iwaizumi": (250, 0.02),
    "Tōru Oikawa": (250, 0.05),
    "Hitoshi Ginjima": (440, 0.13),
    "Ren Ōmimi": (440, 0.085),
    "Michinari Akagi": (420, 0.11),
}

WIKI_TITLE_PATTERN = re.compile(r'wikiTitle:\s*"([^"]+)"')


def portrait_resource_name(wiki_title: str) -> str:
    """Return "haikyu-" plus the ASCII slug of the title, matching HaikyuTheme.swift."""
    without_diacritics = "".join(
        character
        for character in unicodedata.normalize("NFKD", wiki_title)
        if not unicodedata.combining(character)
    )
    slug = re.sub(r"[^a-z0-9]+", "-", without_diacritics.lower()).strip("-")
    return f"haikyu-{slug}"


def read_wiki_titles(swift_file: Path) -> list[str]:
    swift_source = swift_file.read_text(encoding="utf-8")
    wiki_titles = []
    for wiki_title in WIKI_TITLE_PATTERN.findall(swift_source):
        if wiki_title not in wiki_titles:
            wiki_titles.append(wiki_title)
    return wiki_titles


def open_url(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": REQUEST_USER_AGENT})
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
        return response.read()


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
    if wiki_title in FACE_CROP_OVERRIDES:
        square_size, crop_top_share = FACE_CROP_OVERRIDES[wiki_title]
    else:
        square_size, crop_top_share = PORTRAIT_PIXEL_SIZE, DEFAULT_CROP_TOP_SHARE
    return (
        f"scale={square_size}:{square_size}:force_original_aspect_ratio=increase,"
        f"crop={PORTRAIT_PIXEL_SIZE}:{PORTRAIT_PIXEL_SIZE}:"
        f"(iw-{PORTRAIT_PIXEL_SIZE})/2:(ih-{PORTRAIT_PIXEL_SIZE})*{crop_top_share}"
    )


def download_portrait(wiki_title: str, output_file: Path) -> None:
    image_bytes = open_url(page_image_url(wiki_title))
    with tempfile.TemporaryDirectory() as temporary_directory:
        downloaded_file = Path(temporary_directory) / "download"
        downloaded_file.write_bytes(image_bytes)
        result = subprocess.run(
            [
                "ffmpeg", "-nostdin", "-loglevel", "error", "-y",
                "-i", str(downloaded_file),
                "-vf", crop_filter(wiki_title),
                "-frames:v", "1", "-q:v", "3",
                str(output_file),
            ],
            capture_output=True,
            text=True,
        )
    if result.returncode != 0:
        output_file.unlink(missing_ok=True)
        raise RuntimeError(f"ffmpeg failed: {result.stderr.strip()}")


def main() -> int:
    argument_parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    argument_parser.add_argument("--swift-file", type=Path, default=DEFAULT_SWIFT_FILE)
    argument_parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIRECTORY)
    argument_parser.add_argument("--force", action="store_true", help="re-download files that already exist")
    arguments = argument_parser.parse_args()

    if shutil.which("ffmpeg") is None:
        print("ffmpeg is not on PATH", file=sys.stderr)
        return 1

    wiki_titles = read_wiki_titles(arguments.swift_file)
    if not wiki_titles:
        print(f"no wikiTitle strings found in {arguments.swift_file}", file=sys.stderr)
        return 1

    arguments.output_dir.mkdir(parents=True, exist_ok=True)
    failed_titles = []
    for wiki_title in wiki_titles:
        output_file = arguments.output_dir / f"{portrait_resource_name(wiki_title)}.jpg"
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
        print(f"{len(failed_titles)} of {len(wiki_titles)} portraits failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
