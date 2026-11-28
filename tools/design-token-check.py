#!/usr/bin/env python3
"""Fails when a Swift file outside DesignSystem.swift sets a raw font size or a raw corner radius.

Every font comes from a `DS.TypeScale` style (or `DS.glyphFont` for a symbol sized to the disc it sits in), and every
corner radius comes from `DS.CornerRadius`, so one change in DesignSystem.swift moves every surface together.

Usage: python3 -B -I tools/design-token-check.py [repository root]
It scans leanring-buddy/*.swift and the two Quick Look extensions' folders, minus leanring-buddy/DesignSystem.swift.
Tests are not scanned, since they render fixtures at chosen sizes.
-B keeps Python from writing a __pycache__ folder into the checkout.

The scan runs over the whole file with comments and string contents removed, so a call broken across lines, such as
`Font.system(` then `size: 21`, is a finding at the line where it starts. A radius on a line that also holds
`Path(roundedRect:` is skipped, since that call draws a shape inside a Canvas, where no DS.CornerRadius step applies.

A shape drawn to its own geometry, such as a cursor or the Callout's outline, ends its line with
`// design-token-exempt: <why>`. A marker with no reason is a finding, and so is a marker on a line with no finding.
"""

import re
import sys
from pathlib import Path

SCANNED_FOLDERS = ["leanring-buddy", "ClickyThemeQuickLook", "ClickyThemeThumbnail"]
DESIGN_SYSTEM_FILE = Path("leanring-buddy") / "DesignSystem.swift"

# A bare number, or one wrapped in a conversion such as CGFloat(15) or Double(4.5).
NUMERIC_LITERAL = r"(?:(?:CGFloat|Double|Float|Int)?\(\s*)?-?\d[\d.]*"
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
    # .font(.headline), .font(.caption.weight(.bold)), .font(.headline.bold()), .font(Font.title), Font.body
    re.compile(r"\.font\(\s*(?:Font\s*)?\." + TEXT_STYLES + r"\b"),
    re.compile(r"\bFont\." + TEXT_STYLES + r"\b"),
    # Font.custom("Arial", size: 21), .font(.custom("Arial", size: 21))
    re.compile(r"\bFont\.custom\("),
    re.compile(r"\.font\(\s*\.custom\("),
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


def findings_in_code(code: str) -> list[tuple[int, int, str]]:
    """Returns each finding in a whole file's code as (first line, last line, message), counting lines from 0.

    `code` has one entry per source line, joined with newlines, with comments and string contents already removed, so a
    pattern can match across a line break and the match still maps back to its lines.
    """
    found: list[tuple[int, int, str]] = []
    code_lines = code.split("\n")

    def lines_of(match: re.Match[str]) -> tuple[int, int]:
        first_line = code.count("\n", 0, match.start())
        last_line = code.count("\n", 0, match.end() - 1 if match.end() > match.start() else match.end())
        return first_line, last_line

    def excerpt_of(match: re.Match[str]) -> str:
        return " ".join(code[match.start():match.end()].split()).replace("( ", "(")

    for pattern in RADIUS_PATTERNS:
        for match in pattern.finditer(code):
            first_line, last_line = lines_of(match)
            if "Path(roundedRect:" in code_lines[first_line]:
                continue
            found.append((first_line, last_line, RADIUS_MESSAGE.format(found=excerpt_of(match))))
    for pattern in SWIFTUI_FONT_PATTERNS:
        for match in pattern.finditer(code):
            first_line, last_line = lines_of(match)
            found.append((first_line, last_line, SWIFTUI_FONT_MESSAGE.format(found=excerpt_of(match))))
    for pattern in APPKIT_FONT_PATTERNS:
        for match in pattern.finditer(code):
            first_line, last_line = lines_of(match)
            found.append((first_line, last_line, APPKIT_FONT_MESSAGE.format(found=excerpt_of(match))))
    return found


def scan_file(repository_root: Path, swift_file: Path) -> list[str]:
    relative_path = swift_file.relative_to(repository_root)
    messages: list[str] = []
    code_lines: list[str] = []
    comments_by_line: dict[int, str] = {}
    for line_index, line in enumerate(swift_file.read_text(encoding="utf-8").splitlines()):
        if line.lstrip().startswith("//"):
            code_lines.append("")
            continue
        code, comment = split_code_and_comment(line)
        code_lines.append(without_string_contents(code))
        if comment:
            comments_by_line[line_index] = comment
    findings = findings_in_code("\n".join(code_lines))

    lines_a_finding_spans = {line_index for first_line, last_line, _ in findings for line_index in range(first_line, last_line + 1)}
    lines_with_a_valid_marker: set[int] = set()
    for line_index, comment in sorted(comments_by_line.items()):
        marker = MARKER.search(comment)
        if marker is not None:
            if not re.search(r"\w", marker.group(1)):
                messages.append(f"{relative_path}:{line_index + 1}: {EMPTY_MARKER_MESSAGE}")
            elif line_index not in lines_a_finding_spans:
                messages.append(f"{relative_path}:{line_index + 1}: {STALE_MARKER_MESSAGE}")
            else:
                lines_with_a_valid_marker.add(line_index)
        elif MARKER_WITHOUT_COLON.search(comment):
            messages.append(f"{relative_path}:{line_index + 1}: {EMPTY_MARKER_MESSAGE}")
    for first_line, last_line, finding in findings:
        # A marker on any line the call spans exempts it.
        if any(line_index in lines_with_a_valid_marker for line_index in range(first_line, last_line + 1)):
            continue
        # A marker with no reason, or a stale one, was reported above, and the finding on its line is not repeated.
        if any(line_index in comments_by_line and MARKER.search(comments_by_line[line_index]) for line_index in range(first_line, last_line + 1)):
            continue
        messages.append(f"{relative_path}:{first_line + 1}: {finding}")
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
