#!/usr/bin/env bash
# Runs beside record-shot.sh for the study guide shot. Right after the request it glides the mouse out and back, so the
# helper cursor is seen trailing the blue one. The rehearsal then pops the engine out while the guide is written. Once
# the guide's page opens, this scrolls to the first point about the compressor and clicks its timestamp link, which opens
# the video at that moment in a new tab.
# Usage, from the main checkout's root, started just before record-shot.sh:
#   demo/scripts/drive-study-guide-shot.sh demo/public/study-guide.events.txt.raw &
set -u
raw_events_path="$1"
checkout_root="$(git rev-parse --show-toplevel)"
demo_folder="$(cd "$(dirname "$0")/.." && pwd)"
# record-shot.sh builds move-mouse before the recording starts, and this builds click-mouse the first time.
move_mouse="$checkout_root/demo/out/bin/move-mouse"
click_mouse="$checkout_root/demo/out/bin/click-mouse"
if [[ ! -x "$click_mouse" ]]; then
  mkdir -p "$(dirname "$click_mouse")"
  swiftc -O -o "$click_mouse" "$demo_folder/scripts/recorder/click-mouse.swift" || exit 1
fi

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
  awk -v ax="$1" -v ay="$2" -v bx="$3" -v by="$4" 'BEGIN {
    for (s = 1; s <= 30; s++) { t = s / 30; e = t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ^ 2 / 2; printf "%.1f %.1f\n", ax + (bx - ax) * e, ay + (by - ay) * e }
  }' | while read -r point_x point_y; do
    "$move_mouse" "$point_x" "$point_y"
    sleep 0.02
  done
}

# The timestamp link of the first point that mentions the compressor, or the first link when no point does. Notion
# links each point's time to the video with a t= parameter, and it redraws links while the page scrolls, so the pick is
# remembered by its address, not by the element.
pick_link_javascript="(() => { const links = [...document.querySelectorAll('a[href]')].filter(link => /youtu/.test(link.href) && /[?&]t=[0-9]+/.test(link.href)); const link = links.find(candidate => /compress/i.test((candidate.closest('[data-block-id]') || candidate.parentElement).textContent)) || links[0]; if (!link) return 'none'; window.demoLinkAddress = link.href; link.scrollIntoView({ behavior: 'smooth', block: 'center' }); return link.textContent; })()"
# The link's center on screen, in points. Chrome's tab sidebar sits left of the page, so the window's extra width is on the left.
link_point_javascript="(() => { const link = [...document.querySelectorAll('a[href]')].find(candidate => candidate.href === window.demoLinkAddress); if (!link) return 'none'; const box = link.getBoundingClientRect(); const pageLeft = window.screenX + (window.outerWidth - window.innerWidth); const pageTop = window.screenY + (window.outerHeight - window.innerHeight); return Math.round(pageLeft + box.left + box.width / 2) + ' ' + Math.round(pageTop + box.top + box.height / 2); })()"

# The helper cursor appears about 1.5 seconds after the request. A glide out and back while Clicky confirms shows it
# trailing the blue cursor, and ends before the rehearsal says "pop this out" about 7 seconds after the request.
# It starts and ends at record-shot.sh's default mouse point.
wait_for_log_line 'saying "make me' || exit 1
sleep 2.3
glide_mouse 1110 680 880 560
sleep 0.4
glide_mouse 880 560 1110 680

# The Notion tab comes forward about 2 seconds after the request, and the page takes a few more to draw.
wait_for_log_line 'saying "open my study guide' || exit 1
sleep 6
echo "picked link: $(run_in_front_tab "$pick_link_javascript")"
sleep 2
read -r link_x link_y <<< "$(run_in_front_tab "$link_point_javascript")"
if [[ ! "$link_x" =~ ^[0-9]+$ || ! "$link_y" =~ ^[0-9]+$ ]]; then
  echo "no timestamp link to click" >&2
  exit 1
fi
# record-shot.sh leaves the mouse at its default point, 1110, 680.
glide_mouse 1110 680 "$link_x" "$link_y"
sleep 0.6
"$click_mouse" "$link_x" "$link_y"
echo "clicked $link_x $link_y"
