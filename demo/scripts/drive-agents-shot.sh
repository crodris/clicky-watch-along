#!/usr/bin/env bash
# Runs beside record-shot.sh for the two sub-agents shot. Once both sub-agents run, this opens the agent list with
# shift + option, so the list shows "2 running", then glides the mouse out and back, so both helper triangles are seen
# trailing the blue one in formation.
# Usage, from the main checkout's root, started just before record-shot.sh:
#   demo/scripts/drive-agents-shot.sh demo/public/agents.events.txt.raw &
set -u
raw_events_path="$1"
checkout_root="$(git rev-parse --show-toplevel)"
verify_script="$checkout_root/.claude/skills/verify-clicky/verify-clicky.sh"
# record-shot.sh builds move-mouse before the recording starts.
move_mouse="$checkout_root/demo/out/bin/move-mouse"

# Waits up to 5 minutes for the app log to contain the text.
wait_for_log_line() {
  for _ in $(seq 1 1200); do
    grep -q "$1" "$raw_events_path" 2>/dev/null && return 0
    sleep 0.25
  done
  return 1
}

# Moves the mouse from one point to another in 30 eased steps, about 1.5 seconds. The points are worked out in one awk
# call, since starting a process per step doubles the glide's length.
glide_mouse() {
  awk -v ax="$1" -v ay="$2" -v bx="$3" -v by="$4" 'BEGIN {
    for (s = 1; s <= 30; s++) { t = s / 30; e = t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ^ 2 / 2; printf "%.1f %.1f\n", ax + (bx - ax) * e, ay + (by - ay) * e }
  }' | while read -r point_x point_y; do
    "$move_mouse" "$point_x" "$point_y"
    sleep 0.02
  done
}

# The 3D model sub-agent spawns about 1.5 seconds after its request, while the study guide sub-agent writes for about
# 12 seconds more, so the list opens while both run.
wait_for_log_line 'saying "build me' || exit 1
sleep 2.5
"$verify_script" key agents-list
sleep 3.5
"$verify_script" key agents-list
# It starts and ends at record-shot.sh's default mouse point.
sleep 0.6
glide_mouse 1110 680 880 560
sleep 0.4
glide_mouse 880 560 1110 680
