#!/usr/bin/env bash
# Runs beside record-shot.sh for the study guide shot. While the guide is written it glides the mouse out and back, so
# the wingman is seen following the blue cursor, then opens the agent list with shift + option and closes it 4 seconds
# later. It scrolls the Notion page once it has opened.
# Usage, from the main checkout's root, started just before record-shot.sh:
#   demo/scripts/drive-study-guide-shot.sh demo/public/study-guide.events.txt.raw &
set -u
raw_events_path="$1"
checkout_root="$(git rev-parse --show-toplevel)"
verify_script="$checkout_root/.claude/skills/verify-clicky/verify-clicky.sh"
# record-shot.sh builds it before the recording starts.
move_mouse="$checkout_root/demo/out/bin/move-mouse"

# Waits up to 5 minutes for the app log to contain the text.
wait_for_log_line() {
  for _ in $(seq 1 1200); do
    grep -q "$1" "$raw_events_path" 2>/dev/null && return 0
    sleep 0.25
  done
  return 1
}

# Moves the mouse from one point to another in 30 eased steps, about 1 second. The points are worked out in one awk
# call, since starting a process per step doubles the glide's length.
glide_mouse() {
  awk -v ax="$1" -v ay="$2" -v bx="$3" -v by="$4" 'BEGIN {
    for (s = 1; s <= 30; s++) { t = s / 30; e = t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ^ 2 / 2; printf "%.1f %.1f\n", ax + (bx - ax) * e, ay + (by - ay) * e }
  }' | while read -r point_x point_y; do
    "$move_mouse" "$point_x" "$point_y"
    sleep 0.02
  done
}

# The glide starts once Clicky has confirmed the request and the chip under the cursor has faded.
# It starts and ends at record-shot.sh's default mouse point.
wait_for_log_line 'saying "make me' || exit 1
sleep 4.2
glide_mouse 1110 680 880 560
sleep 0.6
glide_mouse 880 560 1110 680
sleep 0.7
"$verify_script" key agents-list
sleep 4
"$verify_script" key agents-list

# The Notion tab comes forward about 2 seconds after the request, and the page takes a few more to draw.
wait_for_log_line 'saying "open my study guide' || exit 1
sleep 6
for scroll_pixels in 520 520 620; do
  osascript -e "tell application \"Google Chrome\" to execute active tab of front window javascript \"(() => { const scroller = [...document.querySelectorAll('.notion-scroller')].sort((a, b) => b.scrollHeight - a.scrollHeight)[0]; if (!scroller) return 'no scroller'; scroller.scrollBy({ top: $scroll_pixels, behavior: 'smooth' }); return 'scrolled'; })()\""
  sleep 3
done
