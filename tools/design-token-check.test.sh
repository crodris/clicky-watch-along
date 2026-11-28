#!/usr/bin/env bash
# Pins what tools/design-token-check.py flags, what it passes, and that each message names the token to use.
# Each case writes one Swift file into a fixture repository and runs the check on it.
set -euo pipefail
# No Python started by this test writes bytecode into the checkout.
export PYTHONDONTWRITEBYTECODE=1
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
  check_output="$(python3 -B -I "$script" "$root" 2>&1)" || check_status=$?
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
  '    Text("x").font(.headline)' 'raw font ".font(.headline"' "$font_fix"
expect_findings "a SwiftUI caption text style" leanring-buddy Label.swift \
  '    Text("x").font(.caption2)' 'raw font ".font(.caption2"'
expect_findings "a custom font" leanring-buddy Label.swift \
  '    Text("x").font(Font.custom("Menlo", size: 11))' 'raw font "Font.custom("'

# Calls broken across lines, wrapped numbers, and custom or text-style fonts the first version missed.
expect_findings "Font.system split across lines" leanring-buddy Label.swift \
  $'    .font(Font.system(\n        size: 21, weight: .bold))' 'raw font ".system(size:"' 'leanring-buddy/Label.swift:1:'
expect_findings "a radius wrapped in CGFloat" leanring-buddy Card.swift \
  '    RoundedRectangle(cornerRadius: CGFloat(15))' 'raw corner radius "cornerRadius: CGFloat(15"' "$radius_fix"
expect_findings "a radius constant wrapped in CGFloat" leanring-buddy Card.swift \
  '    static let cornerRadius: CGFloat = CGFloat(15)' 'raw corner radius'
expect_findings "a custom font on .font(.custom(...))" leanring-buddy Label.swift \
  '    Text("x").font(.custom("Arial", size: 21))' 'raw font ".font(.custom("' "$font_fix"
expect_findings "a text style with a weight" leanring-buddy Label.swift \
  '    Text("x").font(.caption.weight(.bold))' 'raw font ".font(.caption"'
expect_findings "a text style with bold()" leanring-buddy Label.swift \
  '    Text("x").font(.headline.bold())' 'raw font ".font(.headline"'
expect_findings "a Font text style" leanring-buddy Label.swift \
  '    Text("x").font(Font.title)' 'raw font ".font(Font.title"'
expect_findings "an NSFont size wrapped in CGFloat" leanring-buddy Label.swift \
  '    let font = NSFont.systemFont(ofSize: CGFloat(12))' 'raw font "systemFont(ofSize: CGFloat(12"'
expect_findings "a finding on a later line keeps its line number" leanring-buddy Label.swift \
  $'    let a = 1\n    Text("x").font(\n        .system(\n            size: 9))' 'leanring-buddy/Label.swift:3:'
expect_findings "a split call with no marker" leanring-buddy Label.swift \
  $'    .font(.system(\n        size: 9))' 'leanring-buddy/Label.swift:1:'
expect_clean "an exemption on the last line of a split call" leanring-buddy Label.swift \
  $'    .font(.system(\n        size: 9)) // design-token-exempt: drawn to a 9 point badge'
expect_clean "a rounded rect path inside a Canvas" leanring-buddy Icon.swift \
  $'    let path = Path(roundedRect: rect, cornerRadius: 3)'

# One call is one finding, and a finding after a comment or a string still reports its own line.
expect_findings "a Font text style is one finding" leanring-buddy Label.swift \
  '    Text("x").font(Font.title)' 'design-token-check: 1 finding.'
expect_findings "a finding after a multi-line string keeps its line number" leanring-buddy Label.swift \
  $'    let text = """\n    .font(.system(size: 9))\n    """\n    Text("x").font(.system(size: 12))' 'leanring-buddy/Label.swift:4:' 'design-token-check: 1 finding.'
expect_findings "a finding after a block comment keeps its line number" leanring-buddy Label.swift \
  $'    /* one\n       two */ RoundedRectangle(cornerRadius: 7)' 'leanring-buddy/Label.swift:2:'
expect_findings "code after a closed block comment on its own line" leanring-buddy Label.swift \
  '    /* note */ RoundedRectangle(cornerRadius: 7)' 'leanring-buddy/Label.swift:1:'
expect_findings "code after an interpolation with a quote" leanring-buddy Label.swift \
  '    Text("a \(name("b")) c").font(.system(size: 9))' 'raw font ".system(size:"'

# Forms that pass.
expect_clean "a rounded rect path whose radius is on the next line" leanring-buddy Icon.swift \
  $'    let path = Path(roundedRect: rect,\n                    cornerRadius: 3)'
expect_clean "a formatted example inside a multi-line string" leanring-buddy Doc.swift \
  $'    let example = """\n    Text("x").font(.system(\n        size: 21))\n    RoundedRectangle(cornerRadius: 7)\n    """'
expect_clean "a formatted example inside a raw string" leanring-buddy Doc.swift \
  $'    let example = #"Text("x").font(.system(size: 21)) and cornerRadius: 7"#\n    let multiLine = #"""\n    .font(.system(\n        size: 21))\n    """#'
expect_clean "a formatted example inside a block comment" leanring-buddy Doc.swift \
  $'    /* .font(.system(\n        size: 21)) */'
expect_clean "a formatted example inside a nested block comment" leanring-buddy Doc.swift \
  $'    /* outer /* inner */ .font(.system(\n        size: 21)) RoundedRectangle(cornerRadius: 7) */'
expect_clean "a // inside a multi-line string" leanring-buddy Doc.swift \
  $'    let url = """\n    https://example.com // cornerRadius: 3\n    """'
expect_clean "an interpolation holding a string with a quote" leanring-buddy Doc.swift \
  '    let text = "a \(name("cornerRadius: 3")) b"'
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
expect_clean "a comment on its own line that names the marker" leanring-buddy Cursor.swift \
  $'    // Write // design-token-exempt: <why> at the end of a shape\'s line.\n    /// design-token-exempt: is documented here.'
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
# -B keeps the check from leaving a __pycache__ folder in the checkout, wherever a Python import would write one.
if ! grep -q 'python3 -B -I "$checkout_root/tools/design-token-check.py"' "$repository/tools/swift-check.sh"; then
  echo "FAIL: tools/swift-check.sh does not run design-token-check.py with python3 -B"
  failures=$((failures + 1))
fi
if ! grep -q 'python3 -B -I ../tools/design-token-check.py' "$repository/.github/workflows/ci.yml"; then
  echo "FAIL: .github/workflows/ci.yml does not run design-token-check.py with python3 -B"
  failures=$((failures + 1))
fi
if [ -e "$repository/tools/__pycache__" ]; then
  echo "FAIL: running the check left tools/__pycache__ in the checkout"
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
