#!/usr/bin/env bash
# Runs beside record-shot.sh for the two sub-agents shot. It first hides the chat replay of a live stream's recording,
# which shows viewers' comments beside the video. When the learner asks what the task agent found, it brings the agent's
# Notion page forward and scrolls through it while Clicky speaks. Once both sub-agents run, it opens the agent list with
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

# Runs JavaScript in Chrome's front tab and prints what it returns.
run_in_front_tab() {
  osascript -e "tell application \"Google Chrome\" to execute active tab of front window javascript \"$1\""
}

# Moves the mouse from one point to another in 30 eased steps, about 1.5 seconds. The points are worked out in one awk
# call, since starting a process per step doubles the glide's length.
glide_mouse() {
  awk -v start_x="$1" -v start_y="$2" -v end_x="$3" -v end_y="$4" 'BEGIN {
    for (step = 1; step <= 30; step++) { progress = step / 30; eased = progress < 0.5 ? 2 * progress * progress : 1 - (-2 * progress + 2) ^ 2 / 2; printf "%.1f %.1f\n", start_x + (end_x - start_x) * eased, start_y + (end_y - start_y) * eased }
  }' | while read -r point_x point_y; do
    "$move_mouse" "$point_x" "$point_y"
    sleep 0.02
  done
}

# A style rule hides the chat replay whether YouTube shows it open or collapsed, so this waits until the page has one.
hide_chat_javascript="(() => { if (!document.querySelector('ytd-live-chat-frame')) return 'no chat'; const style = document.createElement('style'); style.textContent = 'ytd-live-chat-frame { display: none !important; }'; document.head.appendChild(style); return 'hidden'; })()"
for _ in $(seq 1 40); do
  [[ "$(run_in_front_tab "$hide_chat_javascript")" == hidden ]] && echo "hid the chat replay" && break
  sleep 0.5
done

# The 3D model sub-agent spawns about 1.5 seconds after its request, and the study guide sub-agent finishes about 4
# seconds after that, so the list opens as soon as both run.
wait_for_log_line 'saying "build me' || exit 1
sleep 1.6
"$verify_script" key agents-list
sleep 3.5
"$verify_script" key agents-list
# It starts and ends at record-shot.sh's default mouse point.
sleep 0.6
glide_mouse 1110 680 880 560
sleep 0.4
glide_mouse 880 560 1110 680

# The task agent's page opened in a background tab when it finished. While Clicky speaks the answer, the page comes
# forward and scrolls down a screen at a time.
wait_for_log_line 'saying "what did you find' || exit 0
osascript <<'APPLESCRIPT'
tell application "Google Chrome"
  set tabIndex to 0
  repeat with candidateIndex from 1 to (count of tabs of front window)
    if URL of tab candidateIndex of front window contains "notion." then set tabIndex to candidateIndex
  end repeat
  if tabIndex > 0 then set active tab index of front window to tabIndex
end tell
APPLESCRIPT
scroll_a_screen_javascript="(() => { const scroller = [...document.querySelectorAll('.notion-scroller')].sort((a, b) => b.scrollHeight - a.scrollHeight)[0]; if (!scroller) return 'no scroller'; scroller.scrollBy({ top: scroller.clientHeight * 0.6, behavior: 'smooth' }); return 'scrolled'; })()"
sleep 4
for _ in 1 2 3; do
  run_in_front_tab "$scroll_a_screen_javascript" > /dev/null
  sleep 3.5
done
