#!/usr/bin/env python3
"""Fails when a Swift file outside DesignSystem.swift sets a raw font size or a raw corner radius.

Every font comes from a `DS.TypeScale` style (or `DS.glyphFont` for a symbol sized to the disc it sits in), and every
corner radius comes from `DS.CornerRadius`, so one change in DesignSystem.swift moves every surface together.

Usage: python3 -I tools/design-token-check.py [repository root]
It scans leanring-buddy/*.swift and the two Quick Look extensions' folders, minus leanring-buddy/DesignSystem.swift.
Tests are not scanned, since they render fixtures at chosen sizes.

A shape drawn to its own geometry, such as a cursor or the Callout's outline, ends its line with
`// design-token-exempt: <why>`. A marker with no reason is a finding, and so is a marker on a line with no finding.
"""

import re
import sys
from pathlib import Path

SCANNED_FOLDERS = ["leanring-buddy", "ClickyThemeQuickLook", "ClickyThemeThumbnail"]
DESIGN_SYSTEM_FILE = Path("leanring-buddy") / "DesignSystem.swift"

NUMERIC_LITERAL = r"-?\d[\d.]*"
TEXT_STYLES = r"(?:largeTitle|title|title2|title3|headline|subheadline|body|callout|caption|caption2|footnote)"

RADIUS_PATTERNS = [
    # RoundedRectangle(cornerRadius: 7), .rect(cornerRadius: 10), .panelKeyboardControl(cornerRadius: 9), UnevenRoundedRectangle(topLeadingRadius: 4, ...)
    re.compile(r"\b(?:cornerRadius|topLeadingRadius|topTrailingRadius|bottomLeadingRadius|bottomTrailingRadius)\s*:\s*" + NUMERIC_LITERAL),
    # view.cornerRadius(8)
    re.compile(r"\.cornerRadius\(\s*" + NUMERIC_LITERAL),
    # static let cornerRadius: CGFloat = 16, layer?.cornerRadius = 6, largestCornerRadius: CGFloat = 22
    re.compile(r"\b[A-Za-z_]*[cC]ornerRadius[A-Za-z_]*\s*(?::\s*CGFloat\s*)?=(?!=)\s*" + NUMERIC_LITERAL),
]

SWIFTUI_FONT_PATTERNS = [
    re.compile(r"\.system\(\s*size\s*:"),
    re.compile(r"\.system\(\s*\." + TEXT_STYLES + r"\b"),
    re.compile(r"\.font\(\s*\." + TEXT_STYLES + r"\s*\)"),
    re.compile(r"\bFont\.custom\("),
]

APPKIT_FONT_PATTERNS = [
    re.compile(r"\b(?:systemFont|boldSystemFont|monospacedSystemFont|monospacedDigitSystemFont)\(\s*ofSize\s*:\s*" + NUMERIC_LITERAL),
    re.compile(r"\bNSFont\(\s*name\s*:"),
]

MARKER = re.compile(r"//\s*design-token-exempt:(.*)$")
MARKER_WITHOUT_COLON = re.compile(r"//\s*design-token-exempt\b")

RADIUS_MESSAGE = (
    'raw corner radius "{found}". Use DS.CornerRadius.swatch (3, a mark of 16 points or less), .chip (6), .control (8), '
    '.row (10), .card (14), or .pill. A shape drawn to its own geometry, such as a cursor or the Callout\'s outline, '
    'ends its line with "// design-token-exempt: <why>".'
)
SWIFTUI_FONT_MESSAGE = (
    'raw font "{found}". Set text in a DS.TypeScale style, such as .font(DS.TypeScale.caption.font), and vary it with '
    ".weight(_:) or .monospaced(): display 120, headline 17, voice 15, title 13, body 13, caption 11, data 11. "
    "A symbol or number sized to the disc or badge it sits in uses DS.glyphFont(pointSize:weight:design:)."
)
APPKIT_FONT_MESSAGE = (
    'raw font "{found}". Measure and draw text at a DS.TypeScale style\'s size, such as '
    "NSFont.systemFont(ofSize: DS.TypeScale.caption.pointSize, weight: .semibold)."
)
EMPTY_MARKER_MESSAGE = (
    'design-token-exempt marker with no reason. Write "// design-token-exempt: <why this value is drawn geometry>", '
    "or delete the marker and use a DS.CornerRadius step or a DS.TypeScale style."
)
STALE_MARKER_MESSAGE = (
    "design-token-exempt marker on a line with no raw font size or corner radius. Remove the stale exemption."
)


def split_code_and_comment(line: str) -> tuple[str, str]:
    """Splits a line at its first `//` that is outside a string literal."""
    in_string = False
    index = 0
    while index < len(line):
        character = line[index]
        if in_string:
            if character == "\\":
                index += 2
                continue
            if character == '"':
                in_string = False
        elif character == '"':
            in_string = True
        elif line.startswith("//", index):
            return line[:index], line[index:]
        index += 1
    return line, ""


def without_string_contents(code: str) -> str:
    """Empties each string literal, so a URL or a message that names `cornerRadius: 3` is not a finding."""
    return re.sub(r'"(?:\\.|[^"\\])*"', '""', code)


def findings_in_code(code: str) -> list[str]:
    found: list[str] = []
    code = without_string_contents(code)
    if "Path(roundedRect:" not in code:
        for pattern in RADIUS_PATTERNS:
            for match in pattern.finditer(code):
                found.append(RADIUS_MESSAGE.format(found=code[match.start():match.end()].rstrip()))
    for pattern in SWIFTUI_FONT_PATTERNS:
        for match in pattern.finditer(code):
            found.append(SWIFTUI_FONT_MESSAGE.format(found=code[match.start():match.end()].rstrip()))
    for pattern in APPKIT_FONT_PATTERNS:
        for match in pattern.finditer(code):
            found.append(APPKIT_FONT_MESSAGE.format(found=code[match.start():match.end()].rstrip()))
    return found


def scan_file(repository_root: Path, swift_file: Path) -> list[str]:
    relative_path = swift_file.relative_to(repository_root)
    messages: list[str] = []
    for line_number, line in enumerate(swift_file.read_text(encoding="utf-8").splitlines(), start=1):
        if line.lstrip().startswith("//"):
            continue
        code, comment = split_code_and_comment(line)
        code_findings = findings_in_code(code)
        marker = MARKER.search(comment) if comment else None
        has_marker_word = bool(comment) and bool(MARKER_WITHOUT_COLON.search(comment))
        if marker is not None:
            has_reason = bool(re.search(r"\w", marker.group(1)))
            if not has_reason:
                messages.append(f"{relative_path}:{line_number}: {EMPTY_MARKER_MESSAGE}")
            elif not code_findings:
                messages.append(f"{relative_path}:{line_number}: {STALE_MARKER_MESSAGE}")
            continue
        if has_marker_word:
            messages.append(f"{relative_path}:{line_number}: {EMPTY_MARKER_MESSAGE}")
        for finding in code_findings:
            messages.append(f"{relative_path}:{line_number}: {finding}")
    return messages


def main() -> int:
    repository_root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    all_messages: list[str] = []
    for folder_name in SCANNED_FOLDERS:
        for swift_file in sorted((repository_root / folder_name).glob("*.swift")):
            if swift_file.relative_to(repository_root) == DESIGN_SYSTEM_FILE:
                continue
            all_messages.extend(scan_file(repository_root, swift_file))
    if all_messages:
        print("\n".join(all_messages))
        noun = "finding" if len(all_messages) == 1 else "findings"
        print(f"design-token-check: {len(all_messages)} {noun}. Every font and corner radius comes from DesignSystem.swift.")
        return 1
    print("design-token-check: no raw font sizes or corner radii")
    return 0


if __name__ == "__main__":
    sys.exit(main())
