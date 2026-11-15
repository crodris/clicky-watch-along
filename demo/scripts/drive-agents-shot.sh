#!/usr/bin/env bash
# Runs beside record-shot.sh for the two sub-agents shot. On YouTube it first hides the chat replay of a live stream's
# recording, which shows viewers' comments beside the video. On x.com it hides the side columns and the replies, starts
# the clip at video_start_seconds once the app launches, muted so its sound never covers Clicky, and pauses it 0.6
# seconds before its end, so X's replay button never shows and the last frame stays up. When the learner asks what the
# task agent found, it brings the agent's Notion page forward and scrolls through it while Clicky speaks. Once both sub-agents run, it opens the agent list with
# shift + option, so the list shows "2 running", then glides the mouse out and back, so both helper triangles are seen
# trailing the blue one in formation.
# Usage, from the main checkout's root, started just before record-shot.sh:
#   demo/scripts/drive-agents-shot.sh demo/public/agents.events.txt.raw [video_start_seconds] &
set -u
raw_events_path="$1"
video_start_seconds="${2:-}"
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
# X's post page keeps its navigation, its trends column, the replies, the reply box with the viewer's avatar, and the
# floating Grok and message buttons beside the clip.
hide_x_page_javascript="(() => { const style = document.createElement('style'); style.textContent = 'header[role=banner], [data-testid=sidebarColumn], [data-testid=BottomBar], [data-testid=inline_reply_offscreen], [data-testid=GrokDrawer], [data-testid=chat-drawer-root], [aria-label*=Conversation] [data-testid=cellInnerDiv]:not(:first-child) { visibility: hidden !important; }'; document.head.appendChild(style); return 'hidden'; })()"
# The largest video, as Clicky picks it, starts at the chosen second and stops just before its end.
start_x_clip_javascript="(() => { const videos = [...document.querySelectorAll('video')]; const video = videos.sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0]; if (!video) return 'no video'; video.muted = true; video.currentTime = ${video_start_seconds:-0}; video.addEventListener('timeupdate', () => { if (video.duration && video.currentTime >= video.duration - 0.6) video.pause(); }); video.play(); return 'started at ' + video.currentTime; })()"

# A start time means the x.com clip. The driver starts before record-shot.sh opens the demo window, so it touches the
# page only once the app has launched, when that window's page has loaded. The edit starts after this point.
if [[ -n "$video_start_seconds" ]]; then
  wait_for_log_line 'Clicky: Starting' || exit 1
  echo "x.com page: $(run_in_front_tab "$hide_x_page_javascript")"
  echo "x.com clip: $(run_in_front_tab "$start_x_clip_javascript")"
else
  for _ in $(seq 1 40); do
    [[ "$(run_in_front_tab "$hide_chat_javascript")" == hidden ]] && echo "hid the chat replay" && break
    sleep 0.5
  done
fi

# The 3D model sub-agent spawns about 1.5 seconds after its request, while the task sub-agent is still working, so the
# list opens as soon as both run.
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
