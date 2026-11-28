#!/usr/bin/env bash
# Pins what tools/design-token-check.py flags, what it passes, and that each message names the token to use.
# Each case writes one Swift file into a fixture repository and runs the check on it.
set -euo pipefail
script="$(cd "$(dirname "$0")" && pwd)/design-token-check.py"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
failures=0
case_number=0

# run_check <folder> <file name> <Swift source>: writes the fixture and leaves the check's output and exit code in
# $check_output and $check_status.
run_check() {
  local folder="$1" file_name="$2" source="$3"
  case_number=$((case_number + 1))
  local root="$scratch/case-$case_number"
  mkdir -p "$root/$folder"
  printf '%s\n' "$source" > "$root/$folder/$file_name"
  check_status=0
  check_output="$(python3 -I "$script" "$root" 2>&1)" || check_status=$?
}

# expect_findings <description> <folder> <file name> <source> <text the output must hold>...
expect_findings() {
  local description="$1" folder="$2" file_name="$3" source="$4"
  shift 4
  run_check "$folder" "$file_name" "$source"
  if [ "$check_status" -ne 1 ]; then
    echo "FAIL: $description: exit $check_status, expected 1"
    echo "$check_output"
    failures=$((failures + 1))
    return
  fi
  local expected_text
  for expected_text in "$@"; do
    if ! grep -qF -- "$expected_text" <<<"$check_output"; then
      echo "FAIL: $description: the output lacks \"$expected_text\""
      echo "$check_output"
      failures=$((failures + 1))
      return
    fi
  done
}

# expect_clean <description> <folder> <file name> <source>
expect_clean() {
  local description="$1" folder="$2" file_name="$3" source="$4"
  run_check "$folder" "$file_name" "$source"
  if [ "$check_status" -ne 0 ] || ! grep -qF "design-token-check: no raw font sizes or corner radii" <<<"$check_output"; then
    echo "FAIL: $description: exit $check_status, expected a clean pass"
    echo "$check_output"
    failures=$((failures + 1))
  fi
}

radius_fix="Use DS.CornerRadius.swatch (3, a mark of 16 points or less), .chip (6), .control (8), .row (10), .card (14), or .pill."
font_fix="Set text in a DS.TypeScale style, such as .font(DS.TypeScale.caption.font)"
glyph_fix="DS.glyphFont(pointSize:weight:design:)"
appkit_fix="DS.TypeScale.caption.pointSize"

# Corner radius forms that fail, each with its file:line and the fix text.
expect_findings "RoundedRectangle literal" leanring-buddy Card.swift \
  '    .background(RoundedRectangle(cornerRadius: 7, style: .continuous))' \
  'leanring-buddy/Card.swift:1:' 'raw corner radius "cornerRadius: 7"' "$radius_fix"
expect_findings "clipShape rect literal" leanring-buddy Card.swift \
  '    .clipShape(.rect(cornerRadius: 10))' 'raw corner radius "cornerRadius: 10"' "$radius_fix"
expect_findings "decimal literal" leanring-buddy Card.swift \
  '    RoundedRectangle(cornerRadius: 2.5)' 'raw corner radius "cornerRadius: 2.5"' "$radius_fix"
expect_findings "a modifier argument" leanring-buddy Card.swift \
  '    .panelKeyboardControl(cornerRadius: 9) { }' 'raw corner radius "cornerRadius: 9"'
expect_findings "uneven corners" leanring-buddy Card.swift \
  '    UnevenRoundedRectangle(topLeadingRadius: 4, bottomTrailingRadius: 4)' 'raw corner radius "topLeadingRadius: 4"' 'raw corner radius "bottomTrailingRadius: 4"'
expect_findings "cornerRadius modifier" leanring-buddy Card.swift \
  '    view.cornerRadius(8)' 'raw corner radius ".cornerRadius(8"'
expect_findings "a named constant set to a literal" leanring-buddy Card.swift \
  '    private static let cornerRadius: CGFloat = 16' 'raw corner radius "cornerRadius: CGFloat = 16"' "$radius_fix"
expect_findings "a CornerRadius name with a suffix" leanring-buddy Card.swift \
  '    static let pictureCornerRadiusInPoints: CGFloat = 4' 'raw corner radius "pictureCornerRadiusInPoints: CGFloat = 4"'
expect_findings "a layer's cornerRadius" leanring-buddy Card.swift \
  '    layer?.cornerRadius = 6' 'raw corner radius "cornerRadius = 6"'
expect_findings "a radius on a continued line" leanring-buddy Card.swift \
  $'    RoundedRectangle(\n        cornerRadius: 5)' 'leanring-buddy/Card.swift:2:'
expect_findings "a Quick Look preview folder" ClickyThemeQuickLook Preview.swift \
  '    RoundedRectangle(cornerRadius: 3)' 'ClickyThemeQuickLook/Preview.swift:1:'
expect_findings "a Quick Look thumbnail folder" ClickyThemeThumbnail Thumbnail.swift \
  '    RoundedRectangle(cornerRadius: 3)' 'ClickyThemeThumbnail/Thumbnail.swift:1:'

# Font forms that fail.
expect_findings "system size literal" leanring-buddy Label.swift \
  '    .font(.system(size: 10, weight: .semibold))' 'raw font ".system(size:"' "$font_fix" "$glyph_fix" 'leanring-buddy/Label.swift:1:'
expect_findings "Font.system with a computed size" leanring-buddy Label.swift \
  '    .font(Font.system(size: diameter * 0.5, weight: .heavy))' 'raw font ".system(size:"'
expect_findings "a token's pointSize passed to system(size:)" leanring-buddy Label.swift \
  '    .font(.system(size: DS.TypeScale.title.pointSize, weight: .bold, design: .monospaced))' 'raw font ".system(size:"' "$font_fix"
expect_findings "NSFont literal size" leanring-buddy Label.swift \
  '    let font = NSFont.systemFont(ofSize: 12, weight: .bold)' 'raw font "systemFont(ofSize: 12"' "$appkit_fix"
expect_findings "NSFont monospaced digit literal size" leanring-buddy Label.swift \
  '    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)' 'raw font "monospacedDigitSystemFont(ofSize: 11"'
expect_findings "bold system font literal size" leanring-buddy Label.swift \
  '    let font = NSFont.boldSystemFont(ofSize: 11)' 'raw font "boldSystemFont(ofSize: 11"'
expect_findings "a SwiftUI text style" leanring-buddy Label.swift \
  '    Text("x").font(.headline)' 'raw font ".font(.headline)"' "$font_fix"
expect_findings "a SwiftUI caption text style" leanring-buddy Label.swift \
  '    Text("x").font(.caption2)' 'raw font ".font(.caption2)"'
expect_findings "a custom font" leanring-buddy Label.swift \
  '    Text("x").font(Font.custom("Menlo", size: 11))' 'raw font "Font.custom("'

# Forms that pass.
expect_clean "a DS corner radius token" leanring-buddy Card.swift \
  '    RoundedRectangle(cornerRadius: DS.CornerRadius.row, style: .continuous)'
expect_clean "a computed radius" leanring-buddy Card.swift \
  $'    RoundedRectangle(cornerRadius: side * 0.02)\n    let r = min(bodyHeight / 2, largestCornerRadius)\n    layer.cornerRadius = dotDiameter / 2'
expect_clean "a radius parameter with no value" leanring-buddy Card.swift \
  $'    let cornerRadius: CGFloat\n    func panelKeyboardControl(cornerRadius: CGFloat, action: () -> Void) {}'
expect_clean "a Canvas rounded rect path" leanring-buddy Icon.swift \
  '    Path(roundedRect: CGRect(x: 3.5, y: 4.5, width: 19, height: 14), cornerRadius: 2.5)'
expect_clean "a font from the scale" leanring-buddy Label.swift \
  $'    .font(DS.TypeScale.caption.font.weight(.semibold))\n    .font(DS.glyphFont(pointSize: 12, weight: .bold))'
expect_clean "an NSFont sized by a token" leanring-buddy Label.swift \
  $'    let a = NSFont.systemFont(ofSize: DS.TypeScale.voice.pointSize, weight: .bold)\n    let b = NSFont.systemFont(ofSize: fontSize, weight: .semibold)'
expect_clean "a // comment line that names the raw forms" leanring-buddy Card.swift \
  $'    // RoundedRectangle(cornerRadius: 7) and .font(.system(size: 10)) are the old way.\n    /// Use cornerRadius: 7 never.'
expect_clean "a trailing comment that names a raw form" leanring-buddy Card.swift \
  '    let shape = RoundedRectangle(cornerRadius: DS.CornerRadius.card) // was cornerRadius: 12'
expect_clean "a // inside a string" leanring-buddy Card.swift \
  '    let url = "https://example.com/cornerRadius: 3"'
expect_clean "an exemption with a reason" leanring-buddy Cursor.swift \
  '    static let pictureCornerRadiusInPoints: CGFloat = 4 // design-token-exempt: cursor glyph geometry'
expect_clean "an exemption on a font" leanring-buddy Cursor.swift \
  '    .font(.system(size: 10)) // design-token-exempt: drawn to a 10 point badge'
expect_clean "DesignSystem.swift itself" leanring-buddy DesignSystem.swift \
  $'    static let chip: CGFloat = 6\n    var font: Font { .system(size: pointSize, weight: weight, design: design) }\n    static let cornerRadius: CGFloat = 14'

# A marker needs a reason, and it must sit on a line that has a finding.
expect_findings "an exemption with no reason" leanring-buddy Cursor.swift \
  '    static let cornerRadius: CGFloat = 4 // design-token-exempt:' 'design-token-exempt marker with no reason' 'leanring-buddy/Cursor.swift:1:'
expect_findings "an exemption with a blank reason" leanring-buddy Cursor.swift \
  '    static let cornerRadius: CGFloat = 4 // design-token-exempt:   ' 'design-token-exempt marker with no reason'
expect_findings "a marker with no colon" leanring-buddy Cursor.swift \
  '    static let cornerRadius: CGFloat = 4 // design-token-exempt cursor glyph' 'design-token-exempt marker with no reason'
expect_findings "a stale exemption" leanring-buddy Cursor.swift \
  '    RoundedRectangle(cornerRadius: DS.CornerRadius.chip) // design-token-exempt: cursor glyph geometry' 'Remove the stale exemption' 'leanring-buddy/Cursor.swift:1:'

# The last line counts the findings.
expect_findings "the finding count" leanring-buddy Card.swift \
  $'    RoundedRectangle(cornerRadius: 7)\n    .font(.system(size: 10))' 'design-token-check: 2 findings. Every font and corner radius comes from DesignSystem.swift.'
expect_findings "one finding is singular" leanring-buddy Card.swift \
  '    RoundedRectangle(cornerRadius: 7)' 'design-token-check: 1 finding.'

# The check runs ahead of the Swift build in swift-check.sh and in CI's bench job, so no raw value merges.
repository="$(cd "$(dirname "$script")/.." && pwd)"
if ! grep -q 'design-token-check.py' "$repository/tools/swift-check.sh"; then
  echo "FAIL: tools/swift-check.sh does not run design-token-check.py"
  failures=$((failures + 1))
fi
if ! grep -q 'design-token-check.py' "$repository/.github/workflows/ci.yml" || ! grep -q 'design-token-check.test.sh' "$repository/.github/workflows/ci.yml"; then
  echo "FAIL: .github/workflows/ci.yml does not run design-token-check.py and its test"
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  exit 1
fi
echo "design-token-check.test.sh: every raw form fails with its fix, and every token form and exemption passes, and swift-check.sh and CI run the check"
