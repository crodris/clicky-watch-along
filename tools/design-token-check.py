#!/usr/bin/env python3
"""Fails when a Swift file outside DesignSystem.swift sets a raw font size or a raw corner radius.

Every font comes from a `DS.TypeScale` style (or `DS.glyphFont` for a symbol sized to the disc it sits in), and every
corner radius comes from `DS.CornerRadius`, so one change in DesignSystem.swift moves every surface together.

Usage: python3 -B -I tools/design-token-check.py [repository root]
It scans leanring-buddy/*.swift and the two Quick Look extensions' folders, minus leanring-buddy/DesignSystem.swift.
Tests are not scanned, since they render fixtures at chosen sizes.
-B keeps Python from writing a __pycache__ folder into the checkout.

The scan runs over the whole file with comments (line, and block with nesting) and string contents (single-line,
multi-line, and raw) removed, so a call broken across lines, such as `Font.system(` then `size: 21`, is a finding at the
line where it starts, and a formatted example inside a comment or a string is not. A radius anywhere inside a
`Path(roundedRect:` call is skipped, since that call draws a shape inside a Canvas, where no DS.CornerRadius step applies.

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


def end_of_string_literal(text: str, quote_index: int, hash_count: int) -> int:
    """Returns the index after the string literal whose opening quote is at `quote_index`.

    `hash_count` is the number of `#` before the opening quote, so a raw string and a raw multi-line string close
    only on a quote followed by that many `#`. An escape is a backslash followed by the same number of `#`, and `\\(` opens an
    interpolation, which is code and may hold quotes and parentheses of its own.
    """
    is_multi_line = text.startswith('"""', quote_index)
    opening_quotes = '"""' if is_multi_line else '"'
    closing = opening_quotes + "#" * hash_count
    escape = "\\" + "#" * hash_count
    index = quote_index + len(opening_quotes)
    while index < len(text):
        if text.startswith(escape, index):
            index += len(escape)
            if index < len(text) and text[index] == "(":
                index = end_of_interpolation(text, index)
            else:
                index += 1
            continue
        if text.startswith(closing, index):
            return index + len(closing)
        if not is_multi_line and text[index] == "\n":
            return index  # An unterminated single-line string ends at its line.
        index += 1
    return len(text)


def end_of_interpolation(text: str, open_parenthesis_index: int) -> int:
    """Returns the index after the `)` that closes the interpolation opened at `open_parenthesis_index`."""
    depth = 0
    index = open_parenthesis_index
    while index < len(text):
        character = text[index]
        if character == '"':
            index = end_of_string_literal(text, index, 0)
            continue
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    return len(text)


def strip_comments_and_strings(source: str) -> tuple[str, dict[int, str]]:
    """Removes comments and string contents from a whole Swift file, keeping every line break.

    Returns the code and the trailing `//` comment of each line that also holds code, by line number counted from 0, since
    that is where an exemption marker lives. A string becomes two quote marks, so a URL, a message, or a formatted example
    inside a multi-line or raw string names no raw value. A block comment, which may nest, becomes a space.
    A comment on a line of its own is dropped with no record.
    """
    code_parts: list[str] = []
    comments_by_line: dict[int, str] = {}
    line_index = 0
    line_has_code = False
    index = 0
    while index < len(source):
        character = source[index]
        if source.startswith("//", index):
            end_of_comment = source.find("\n", index)
            if end_of_comment == -1:
                end_of_comment = len(source)
            if line_has_code:
                comments_by_line[line_index] = source[index:end_of_comment]
            index = end_of_comment
        elif source.startswith("/*", index):
            depth = 0
            while index < len(source):
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                    if depth == 0:
                        break
                else:
                    if source[index] == "\n":
                        code_parts.append("\n")
                        line_index += 1
                        line_has_code = False
                    index += 1
            code_parts.append(" ")
        elif character == "#" or character == '"':
            hash_count = 0
            while source.startswith("#", index + hash_count):
                hash_count += 1
            quote_index = index + hash_count
            if source.startswith('"', quote_index):
                end_index = end_of_string_literal(source, quote_index, hash_count)
                literal = source[index:end_index]
                code_parts.append('""' + "\n" * literal.count("\n"))
                line_index += literal.count("\n")
                line_has_code = True
                index = end_index
            else:
                # A `#` that opens no string, such as `#if` or `#selector`.
                code_parts.append(source[index:quote_index])
                line_has_code = True
                index = quote_index
        else:
            code_parts.append(character)
            if character == "\n":
                line_index += 1
                line_has_code = False
            elif not character.isspace():
                line_has_code = True
            index += 1
    return "".join(code_parts), comments_by_line


def ranges_of_calls_starting_with(code: str, call_start: str) -> list[tuple[int, int]]:
    """Returns the span of each `call_start(...)` call in `code`, from its start to its closing parenthesis."""
    spans: list[tuple[int, int]] = []
    search_from = 0
    while True:
        start = code.find(call_start, search_from)
        if start == -1:
            return spans
        depth = 0
        end = len(code)
        for index in range(start, len(code)):
            if code[index] == "(":
                depth += 1
            elif code[index] == ")":
                depth -= 1
                if depth == 0:
                    end = index + 1
                    break
        spans.append((start, end))
        search_from = start + len(call_start)


def findings_in_code(code: str) -> list[tuple[int, int, str]]:
    """Returns each finding in a whole file's code as (first line, last line, message), counting lines from 0.

    `code` has one entry per source line, joined with newlines, with comments and string contents already removed, so a
    pattern can match across a line break and the match still maps back to its lines. A match that falls inside a
    `Path(roundedRect:` call is skipped, wherever the call breaks its lines. Two matches of one kind that overlap are one
    finding, so `.font(Font.title)` is reported once.
    """
    def lines_of(match: re.Match[str]) -> tuple[int, int]:
        first_line = code.count("\n", 0, match.start())
        last_line = code.count("\n", 0, match.end() - 1 if match.end() > match.start() else match.end())
        return first_line, last_line

    def excerpt_of(match: re.Match[str]) -> str:
        return " ".join(code[match.start():match.end()].split()).replace("( ", "(")

    canvas_path_spans = ranges_of_calls_starting_with(code, "Path(roundedRect:")
    pattern_groups = [
        (RADIUS_PATTERNS, RADIUS_MESSAGE),
        (SWIFTUI_FONT_PATTERNS, SWIFTUI_FONT_MESSAGE),
        (APPKIT_FONT_PATTERNS, APPKIT_FONT_MESSAGE),
    ]
    found: list[tuple[int, int, str]] = []
    for patterns, message in pattern_groups:
        matches = sorted(
            (match for pattern in patterns for match in pattern.finditer(code)),
            key=lambda match: (match.start(), -match.end()),
        )
        furthest_end_of_a_kept_match = -1
        for match in matches:
            if message is RADIUS_MESSAGE and any(start <= match.start() < end for start, end in canvas_path_spans):
                continue
            if match.start() < furthest_end_of_a_kept_match:
                continue
            furthest_end_of_a_kept_match = match.end()
            first_line, last_line = lines_of(match)
            found.append((first_line, last_line, message.format(found=excerpt_of(match))))
    return found


def scan_file(repository_root: Path, swift_file: Path) -> list[str]:
    relative_path = swift_file.relative_to(repository_root)
    messages: list[str] = []
    code, comments_by_line = strip_comments_and_strings(swift_file.read_text(encoding="utf-8"))
    findings = findings_in_code(code)

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
