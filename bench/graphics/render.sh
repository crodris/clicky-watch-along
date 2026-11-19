#!/bin/zsh
# Renders each bakeoff card to a 1600x900 PNG next to its page. Run node bench/bakeoffGraphics.ts first.
set -euo pipefail
cd "${0:A:h}"
chrome="${CHROME_PATH:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
profile="$(mktemp -d)"
trap 'rm -rf "$profile"' EXIT
render() {
  local page=$1 png=$2
  "$chrome" --headless --disable-gpu --hide-scrollbars --user-data-dir="$profile" --window-size=1600,900 \
    --virtual-time-budget=4000 --screenshot="$PWD/$png" "file://$PWD/$page" 2>/dev/null
  [[ -s "$png" ]] || { print -u2 "no PNG for $page"; exit 1; }
  print "wrote bench/graphics/$png"
}
render "by-model-grid.html?metric=time" time-by-model.png
render "by-model-grid.html?metric=cost" cost-by-model.png
for page in models-after-bakeoff quiz-plan-by-model picture-flows-rerun scene-renders; do
  render $page.html $page.png
done
render render-round-one.html render-round-one.png
render experiments-by-model.html experiments-by-model.png
for pair in heart cannon lever pendulum; do
  render "same-request.html?pair=$pair" same-request-$pair.png
done
