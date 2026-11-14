#!/usr/bin/env bash
# Records one demo shot: a Chrome window on the MacBook's Retina display, with system audio, while the Debug app
# plays rehearsal steps.
# Every app log line is stamped with seconds since the recording started, so the edit can sync captions and zooms.
#
# Usage: demo/scripts/record-shot.sh <shot-name> "<rehearsal steps>" <url> [video-start-seconds] [mouse-x mouse-y]
# Run from the main checkout's root, with a Worker that checkout's verify-clicky.sh started on port 8787.
set -euo pipefail

shot_name="$1"
rehearsal_steps="$2"
page_url="$3"
video_start_seconds="${4:-}"
mouse_x="${5:-1110}"
mouse_y="${6:-680}"

# The checkout you run it from supplies the app build and the Worker, and the footage lands next to this script.
# Run it from the main checkout, whose Xcode build holds the Accessibility grant that keeps the blue cursor on screen.
checkout_root="$(git rev-parse --show-toplevel)"
verify_script="$checkout_root/.claude/skills/verify-clicky/verify-clicky.sh"
demo_folder="$(cd "$(dirname "$0")/.." && pwd)"
binary_folder="$demo_folder/out/bin"
footage_folder="$demo_folder/public"
mkdir -p "$binary_folder" "$footage_folder"

# The MacBook's built-in Retina display is index 0, sorted by display ID, in the recorder's own listing. It records at
# 2 pixels per point, so the edit's 3x zoom on Clicky's small text stays sharp, where the 1080p external monitor
# (index 1) blurs. The recorder keeps only the demo window's 16:9 area below the menu bar.
recording_display_index="${RECORDING_DISPLAY_INDEX:-0}"
export RECORDING_SOURCE_RECT="${RECORDING_SOURCE_RECT:-0,38,1710,962}"

if [[ ! -x "$binary_folder/record-display" ]]; then
  swiftc -O -o "$binary_folder/record-display" "$demo_folder/scripts/recorder/record-display.swift"
fi
if [[ ! -x "$binary_folder/move-mouse" ]]; then
  swiftc -O -o "$binary_folder/move-mouse" "$demo_folder/scripts/recorder/move-mouse.swift"
fi

# Each value below reaches AppleScript or JavaScript, so it must be a plain number.
number_pattern='^[0-9]+(\.[0-9]+)?$'
if [[ -n "$video_start_seconds" && ! "$video_start_seconds" =~ $number_pattern ]]; then
  echo "video-start-seconds must be a number of seconds, got: $video_start_seconds" >&2
  exit 2
fi
demo_window_bounds="${DEMO_WINDOW_BOUNDS:-0, 38, 1710, 1000}"
if [[ ! "$demo_window_bounds" =~ ^[0-9]+,\ ?[0-9]+,\ ?[0-9]+,\ ?[0-9]+$ ]]; then
  echo "DEMO_WINDOW_BOUNDS must be four numbers separated by commas, got: $demo_window_bounds" >&2
  exit 2
fi
page_is_youtube_video=false
[[ "$page_url" == *youtube.com/watch* ]] && page_is_youtube_video=true

# YouTube ignores a seek made while its page is still loading, so the start time also goes in the URL.
if [[ -n "$video_start_seconds" && "$page_is_youtube_video" == true ]]; then
  page_url="${page_url}&t=${video_start_seconds%.*}s"
fi

# The app in front before the shot, brought back to the front when the shot ends.
previous_front_bundle_id="$(lsappinfo info -only bundleid "$(lsappinfo front)" | sed -E 's/.*="?([^"]*)"?/\1/')"

demo_window_id=""
recorder_pid=""
log_stamper_pid=""
run_folder=""
app_was_launched=false
cleanup_has_run=false
# Runs in the front tab, which is the demo window's. Any other tab has no saved setting, so nothing changes there.
restore_youtube_volume() {
  osascript -e "tell application \"Google Chrome\" to execute active tab of front window javascript \"(() => { const savedVolume = sessionStorage.getItem('clicky-demo-saved-volume'); if (savedVolume === null) return 'nothing saved'; if (savedVolume === 'none') localStorage.removeItem('yt-player-volume'); else localStorage.setItem('yt-player-volume', savedVolume); sessionStorage.removeItem('clicky-demo-saved-volume'); return 'restored'; })()\"" >/dev/null 2>&1 || true
}
# Stops what the shot started, once, on a normal end or a failure: the recorder, the log stamper and its tail, the
# rehearsal app, the demo window, and the saved YouTube volume, then brings back the app that was in front.
stop_background_work() {
  [[ "$cleanup_has_run" == true ]] && return
  cleanup_has_run=true
  if [[ -n "$recorder_pid" ]]; then
    pkill -INT -f "record-display $recording_display_index $recording_path" 2>/dev/null || true
    wait "$recorder_pid" 2>/dev/null || true
  fi
  [[ -n "$log_stamper_pid" ]] && kill "$log_stamper_pid" 2>/dev/null || true
  # pkill reads its pattern as a regular expression, so the + in "-n +1" goes in brackets.
  [[ -n "$run_folder" ]] && pkill -f "tail -n [+]1 -F $run_folder/app.log" 2>/dev/null || true
  [[ "$app_was_launched" == true ]] && "$verify_script" app-quit >/dev/null 2>&1 || true
  if [[ -n "$demo_window_id" ]]; then
    restore_youtube_volume
    osascript -e "tell application \"Google Chrome\" to close (first window whose id is $demo_window_id)" >/dev/null 2>&1 || true
  fi
  [[ -n "$previous_front_bundle_id" ]] && open -b "$previous_front_bundle_id" 2>/dev/null || true
}
trap stop_background_work EXIT

# A window of its own, in front of every other app on the recorded display, so the shot never touches the tabs
# already open. The URL goes in as an argument, so a quote in it cannot end the AppleScript string.
demo_window_id="$(osascript - "$page_url" <<APPLESCRIPT
on run argv
  tell application "Google Chrome"
    set demoWindow to make new window
    set bounds of demoWindow to {$demo_window_bounds}
    set URL of active tab of demoWindow to (item 1 of argv)
    set index of demoWindow to 1
    activate
    return id of demoWindow
  end tell
end run
APPLESCRIPT
)"
sleep 6
if [[ "$page_is_youtube_video" == true ]]; then
  # Theater mode makes the video, and so the pop-out, as large as the window allows. The demo window is the front one,
  # and Chrome's scripting hangs when a window is named by its id here.
  # The video plays muted, so the footage carries only Clicky's voice. YouTube's player turns a muted video's sound
  # back on unless its own mute button mutes it, and it reads the saved volume setting again on every seek.
  # The button saves the muted state for every later YouTube page, so the tab keeps the old setting in its
  # sessionStorage, and restore_youtube_volume puts it back when the shot ends. YouTube turns its captions on for a
  # muted video, so a style rule in this tab hides them, leaving the caption setting alone.
  seek_to_start=""
  [[ -n "$video_start_seconds" ]] && seek_to_start="video.currentTime = $video_start_seconds;"
  osascript -e "tell application \"Google Chrome\" to execute active tab of front window javascript \"(() => { if (!document.querySelector('ytd-watch-flexy[theater]')) document.querySelector('.ytp-size-button')?.click(); const video = [...document.querySelectorAll('video')].sort((first, second) => second.clientWidth - first.clientWidth)[0]; if (!video) return 'no video'; const hideCaptions = document.createElement('style'); hideCaptions.textContent = '.ytp-caption-window-container { display: none !important; }'; document.head.append(hideCaptions); if (!video.muted) { sessionStorage.setItem('clicky-demo-saved-volume', localStorage.getItem('yt-player-volume') ?? 'none'); document.querySelector('.ytp-mute-button')?.click(); } $seek_to_start video.play(); return String(video.currentTime); })()\""
  sleep 2
fi
"$binary_folder/move-mouse" "$mouse_x" "$mouse_y"

"$verify_script" new-run "demo-$shot_name" >/dev/null
run_folder="$(readlink "$checkout_root/.verify-clicky/current")"

recording_path="$footage_folder/$shot_name.mov"
events_path="$footage_folder/$shot_name.events.txt"
rm -f "$recording_path"

# Wall-clock stamps on the recorder's own lines give the moment the first frame was written.
"$binary_folder/record-display" "$recording_display_index" "$recording_path" \
  | perl -MTime::HiRes=time -ne '$| = 1; printf "%.3f %s", time, $_' > "$footage_folder/$shot_name.recorder.txt" &
recorder_pid=$!
sleep 2

# LaunchServices refuses to start the app (error -10810) while another process holds its log file open,
# so the stamper starts reading only once the app is up. The rehearsal waits 3 seconds before its first step.
app_was_launched=true
"$verify_script" app-launch "$rehearsal_steps"
tail -n +1 -F "$run_folder/app.log" 2>/dev/null \
  | perl -MTime::HiRes=time -ne '$| = 1; printf "%.3f %s", time, $_' > "$events_path.raw" &
log_stamper_pid=$!
# A quiz step waits up to 4 minutes for its question, so a shot gets 10 minutes before it counts as stuck.
rehearsal_finished=false
for _ in $(seq 1 600); do
  if grep -q 'Live scene rehearsal: done' "$run_folder/app.log" 2>/dev/null; then
    rehearsal_finished=true
    break
  fi
  # A crashed app never logs "done", so the wait ends early.
  pgrep -x Clicky >/dev/null 2>&1 || break
  sleep 1
done
if [[ "$rehearsal_finished" != true ]]; then
  echo "the rehearsal never logged 'Live scene rehearsal: done', so the shot is incomplete; see $run_folder/app.log" >&2
  exit 1
fi
# The last spoken line and the cursor's flight back still play after "done".
sleep "${TRAILING_SECONDS:-6}"
stop_background_work

# Rewrite each log stamp as seconds since the recording started.
recording_started_at="$(awk '/recording started/ { print $1; exit }' "$footage_folder/$shot_name.recorder.txt")"
awk -v start="$recording_started_at" '{ stamp = $1; $1 = ""; printf "%.2f%s\n", stamp - start, $0 }' "$events_path.raw" > "$events_path"
rm -f "$events_path.raw"
echo "recorded $recording_path"
grep -E 'rehearsal: saying|Voice command|Frame pop-out|narration|Live scene' "$events_path" || true
