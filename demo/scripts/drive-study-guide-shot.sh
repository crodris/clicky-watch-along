#!/usr/bin/env bash
# Runs beside record-shot.sh for the study guide shot and the quiz miss shot. In the study guide shot, right after the
# request it glides the mouse out and back, so the helper cursor is seen trailing the blue one. The rehearsal then pops
# the engine out while the guide is written, and this opens the agent list through the settings dial while the pop-out builds.
# In both shots, once the guide's page opens, this scrolls down to its key terms and clicks the timestamp of the term
# about the stator vanes or the compressor, which opens the video at that moment in a new tab.
# Usage, from the main checkout's root, started just before record-shot.sh:
#   demo/scripts/drive-study-guide-shot.sh demo/public/study-guide.events.txt.raw &
#   demo/scripts/drive-study-guide-shot.sh demo/public/quiz-miss.events.txt.raw &
set -u
raw_events_path="$1"
checkout_root="$(git rev-parse --show-toplevel)"
verify_script="$checkout_root/.claude/skills/verify-clicky/verify-clicky.sh"
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

# Waits up to 30 seconds for Chrome's front tab to be a Notion page. Clicky checks the guide's page in Notion before it
# brings the tab forward, and that check can take 5 seconds or more when Notion is slow.
wait_for_the_notion_tab_in_front() {
  for _ in $(seq 1 120); do
    [[ "$(osascript -e 'tell application "Google Chrome" to get URL of active tab of front window' 2>/dev/null)" == *notion* ]] && return 0
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
    for (step = 1; step <= 30; step++) {
      progress = step / 30
      eased = progress < 0.5 ? 2 * progress * progress : 1 - (-2 * progress + 2) ^ 2 / 2
      printf "%.1f %.1f\n", start_x + (end_x - start_x) * eased, start_y + (end_y - start_y) * eased
    }
  }' | while read -r point_x point_y; do
    "$move_mouse" "$point_x" "$point_y"
    sleep 0.02
  done
}

# Notion draws blocks far down the page only once they scroll near, so the page first scrolls to its end, where the key
# terms are, and the pick runs once they are drawn.
scroll_to_the_end_javascript="(() => { const scroller = [...document.querySelectorAll('.notion-scroller')].sort((a, b) => b.scrollHeight - a.scrollHeight)[0]; if (!scroller) return 'no scroller'; scroller.scrollTo({ top: scroller.scrollHeight, behavior: 'smooth' }); return 'scrolling'; })()"
# The timestamp link of the first key term about the stator vanes or the compressor, or else the first key term, and
# none when the key terms have not drawn, so the shot never clicks a link above them, such as a review item's. Only a
# link whose text is a time such as (0:50) counts, since the
# video link at the top of the page carries a t= parameter too. Notion redraws links while the page scrolls, so the pick
# is remembered by its address, not by the element.
pick_link_javascript="(() => { const links = [...document.querySelectorAll('a[href]')].filter(link => /youtu/.test(link.href) && /^[(]?[0-9]+:[0-9]{2}[)]?$/.test(link.textContent.trim())); const heading = [...document.querySelectorAll('h1, h2, h3, [class*=header-block]')].find(element => /key terms/i.test(element.textContent)); const headingTop = heading ? heading.getBoundingClientRect().top : Infinity; const termLinks = links.filter(link => link.getBoundingClientRect().top > headingTop); const link = termLinks.find(candidate => /stator|compress/i.test((candidate.closest('[data-block-id]') || candidate.parentElement).textContent)) || termLinks[0]; if (!link) return 'none'; window.demoLinkAddress = link.href; link.scrollIntoView({ behavior: 'smooth', block: 'center' }); return link.textContent; })()"
# The link's center on screen, in points. Chrome's tab sidebar sits left of the page, so the window's extra width is on the left.
link_point_javascript="(() => { const link = [...document.querySelectorAll('a[href]')].find(candidate => candidate.href === window.demoLinkAddress); if (!link) return 'none'; const box = link.getBoundingClientRect(); const pageLeft = window.screenX + (window.outerWidth - window.innerWidth); const pageTop = window.screenY + (window.outerHeight - window.innerHeight); return Math.round(pageLeft + box.left + box.width / 2) + ' ' + Math.round(pageTop + box.top + box.height / 2); })()"

# The helper cursor appears about 1.5 seconds after the request. A glide out and back while Clicky confirms shows it
# trailing the blue cursor, and ends before the rehearsal says "pop this out" about 7 seconds after the request.
# It starts and ends at record-shot.sh's default mouse point.
# The quiz miss shot has no pop-out, so only the study guide shot glides the mouse and opens the agent list.
if [[ "$(basename "$raw_events_path")" == study-guide.* ]]; then
  wait_for_log_line 'saying "make me' || exit 1
  sleep 2.3
  glide_mouse 1110 680 880 560
  sleep 0.4
  glide_mouse 880 560 1110 680

  # The agent list opens while the pop-out builds, so the study guide sub-agent is seen running beside the main agent's
  # work, and it closes before the engine lifts out about 5 seconds after the request.
  wait_for_log_line 'saying "pop this out' || exit 1
  sleep 1
  "$verify_script" key agents-list
  sleep 3.5
  "$verify_script" key escape
fi

# The Notion tab comes forward about 2 seconds after the request, or later when Notion is slow, and the page takes a
# few more seconds to draw.
wait_for_log_line 'saying "open my study guide' || exit 1
if ! wait_for_the_notion_tab_in_front; then
  echo "the study guide's Notion tab never came forward" >&2
  exit 1
fi
sleep 4
run_in_front_tab "$scroll_to_the_end_javascript" > /dev/null
sleep 2.5
echo "picked link: $(run_in_front_tab "$pick_link_javascript")"
# The key terms sit at the bottom of the page, so the smooth scroll takes longer than a scroll within the first screen.
sleep 3
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
