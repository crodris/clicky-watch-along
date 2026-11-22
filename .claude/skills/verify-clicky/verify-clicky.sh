#!/usr/bin/env bash
# Drives Clicky's Worker and Debug app for verification. Run with no arguments for usage.
set -euo pipefail

checkout_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
state_root="$checkout_root/.verify-clicky"
runs_root="$state_root/runs"
current_run_link="$state_root/current"
app_worker_port=8787
default_own_worker_port=8789

usage() {
  cat <<'EOF'
Usage: .claude/skills/verify-clicky/verify-clicky.sh <command> [args]

  new-run <name>            Start an evidence folder and make it current.
  build                     Build this checkout's Debug app in Xcode itself (never xcodebuild) and wait until Xcode reports the build finished. Builds again, up to 3 tries 5 seconds apart, while the build fails or a Swift file under leanring-buddy/ is newer than the app, then fails naming the stale file or the build status.
  doctor                    Health check of the Worker ports, the Debug app, and Chrome. Removes only PID records whose process is gone.
  worker-up [port] [-- wrangler args]
                            Start wrangler dev from this checkout (default port 8789).
                            Pass 8787 only when nothing listens there and the app must use it.
  worker-down [port]        Stop the Workers this script started, or only the one on that port.
  post <route> <body.json> [port]
                            POST a JSON body to a Worker this script started, and save the response in the run.
  app-launch [--brain] [--harness-brain] [--no-app-secret|--wrong-app-secret] [--every-permission] [--room-camera-file <video>] "<steps>"
                          Launch the Debug app with --live-scene-rehearsal "<steps>" and --voice-tool-debug-server.
                          --room-camera-file passes the same Debug argument, so the room art panel loops that video
                          instead of the camera.
                          --brain also passes --brain-takes-every-request, so the router takes every first utterance
                          without writing the flag into the defaults the everyday Clicky shares.
                          --harness-brain also passes --brain-runs-in-the-harness, so voice commands run on the brain in
                          the agent harness instead of POST /voice-command. The two flags go in either order.
                          --no-app-secret makes the Debug app act as if no secret were set, and --wrong-app-secret as if
                          the secret were one the Worker refuses, so the upgrade paths of the harness brain can be driven:
                          with no secret, voice commands use the old Worker router from the start, and with a wrong one,
                          the first command is re-sent on it. They pass the app's own --app-secret-mode none|wrong launch
                          argument and never write or delete the defaults the everyday Clicky shares.
                          --every-permission quits the app and fails when it starts without every permission or onboarding,
                          since its permissions panel would cover a recorded take. record-shot.sh passes it.
  app-wait [seconds]        Wait for "Live scene rehearsal: done" in the app log (default 240).
  app-quit                  Quit the app instance this script launched.
  shot <name>               Save a screenshot of every display into the run.
  key <escape|push-to-talk-tap|dial-hold|dial-release|agents-list>
                            Press that key through System Events, as the learner would, while the app runs.
                            dial-hold presses shift and option and leaves them down, which opens the settings dial under the mouse after 0.3 s.
                            dial-release lets them go, which commits the highlighted item.
                            agents-list holds shift and option, glides the mouse onto the dial's Agents token, releases, which opens the agent list, and puts the mouse back.
                            Keep the mouse 250 points from every screen edge, since an edge shifts the dial.
  scroll <points>           Post one real scroll wheel event at the mouse, in pixels, positive to scroll down (a whole number of up to 6 digits).
                            A large value jumps, as dragging a scroll bar to the end does, and several small ones scroll through.
                            Park the mouse over the scroll area first, such as the approval card's summary.
  menu-icon <status|click>  status prints the app log's line that says where the menu bar icon is and whether macOS shows it.
                            click clicks the icon through the Debug tool server (debug_click_menu_bar_icon), which opens the panel even when the icon sits
                            behind the notch, where its window is not in the window list. Needs a running app from app-launch.
  grant                     Open System Settings at Privacy & Security > Accessibility and show the Debug Clicky.app that app-launch
                            launches in Finder, so Chris can turn its switch on or drag that exact app into the list. app-launch says when it is needed.
  cleanup                   app-quit and worker-down. Evidence stays in .verify-clicky/runs.
EOF
}

current_run_dir() {
  if [[ ! -d "$current_run_link" ]]; then
    start_new_run "unnamed" >/dev/null
  fi
  readlink "$current_run_link"
}

start_new_run() {
  local run_name="$1"
  local run_dir
  run_dir="$runs_root/$(date +%Y%m%d-%H%M%S)-$run_name"
  mkdir -p "$run_dir"
  ln -sfn "$run_dir" "$current_run_link"
  echo "$run_dir"
}

# A PID alone can be reused after a crash or a reboot, so each record also holds the process start time.
process_start_time() {
  ps -o lstart= -p "$1" 2>/dev/null || true
}

record_process() {
  local process_id="$1" record_file="$2"
  printf '%s\t%s\n' "$process_id" "$(process_start_time "$process_id")" >"$record_file"
}

# Prints the recorded PID when that same process still runs. Otherwise removes the stale record and prints nothing.
recorded_process_id() {
  local record_file="$1"
  [[ -f "$record_file" ]] || return 0
  local recorded_id recorded_start_time
  IFS=$'\t' read -r recorded_id recorded_start_time <"$record_file"
  if [[ "$recorded_id" =~ ^[0-9]+$ && -n "$recorded_start_time" && "$(process_start_time "$recorded_id")" == "$recorded_start_time" ]]; then
    echo "$recorded_id"
  else
    rm -f "$record_file"
  fi
}

listener_pid_on_port() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -1 || true
}

process_cwd() {
  lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'
}

# workerd is a child of wrangler's node process, so report the checkout that node runs from.
worker_checkout_for_listener() {
  local listener_pid="$1"
  local parent_pid
  parent_pid="$(ps -o ppid= -p "$listener_pid" | tr -d ' ')"
  process_cwd "$parent_pid"
}

# A body that fails the Zod check gets a 400 from this checkout's Worker code without any model call.
worker_answers_free_probe() {
  local port="$1"
  local probe_status
  probe_status="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/judge-answer" \
    -H 'content-type: application/json' -d '{}' --max-time 5 || true)"
  [[ "$probe_status" == "400" ]]
}

worker_was_started_here() {
  local port="$1"
  local listener_pid recorded_root_id our_tree
  listener_pid="$(listener_pid_on_port "$port")"
  recorded_root_id="$(recorded_process_id "$state_root/worker-$port.pid")"
  [[ -n "$listener_pid" && -n "$recorded_root_id" ]] || return 1
  our_tree="$(descendant_pids "$recorded_root_id")"
  grep -qx "$listener_pid" <<<"$our_tree"
}

worker_log_line_count() {
  local port="$1"
  if worker_was_started_here "$port"; then
    wc -l <"$(cat "$state_root/worker-$port.logpath")" | tr -d ' '
  else
    echo 0
  fi
}

# Prints the "[/route] usage {...}" lines the Worker logged after line <from_line>, and saves them to <output_file>.
# One line per model attempt, so two lines for one request mean one retry.
# A rejected model reply logs "[/video-quiz-plan] attempt N rejected: <reason>" or "[/live-scene] reply failed validation: <reason>".
# Those lines are saved next to it as .rejections.log.
report_usage_lines_since() {
  local port="$1" from_line="$2" output_file="$3"
  local rejections_file="${output_file%.usage.log}.rejections.log"
  if ! worker_was_started_here "$port"; then
    echo "usage lines: unavailable, no Worker this script started is listening on port $port"
    return 0
  fi
  sleep 1
  local new_log_lines
  # console.error lines can carry a wrangler prefix and color codes, so strip ANSI codes and match anywhere in the line.
  # LC_ALL=C keeps BSD sed from failing on a byte that is not valid UTF-8.
  new_log_lines="$(tail -n +"$((from_line + 1))" "$(cat "$state_root/worker-$port.logpath")" | LC_ALL=C sed $'s/\x1b\\[[0-9;]*m//g')"
  grep -oE '\[/[a-z-]+\] (attempt [0-9]+ rejected|reply failed validation): .*' <<<"$new_log_lines" >"$rejections_file" || true
  if [[ -s "$rejections_file" ]]; then
    cat "$rejections_file"
    echo "rejected attempts: $(wc -l <"$rejections_file" | tr -d ' '), saved to $rejections_file"
  else
    rm -f "$rejections_file"
  fi
  grep -oE '\[/[a-z-]+\] usage \{.*' <<<"$new_log_lines" >"$output_file" || true
  local usage_line
  while IFS= read -r usage_line; do
    local route_name="${usage_line%% usage *}"
    # Anthropic and OpenAI name the cache and thinking fields differently.
    echo "$route_name $(jq -c '{
      input_tokens,
      cache_read_input_tokens: (.cache_read_input_tokens // .input_tokens_details.cached_tokens),
      output_tokens,
      thinking_tokens: (.output_tokens_details.thinking_tokens // .output_tokens_details.reasoning_tokens)
    }' <<<"${usage_line#* usage }")"
  done <"$output_file"
  echo "usage lines: $(wc -l <"$output_file" | tr -d ' '), saved to $output_file"
}

# Xcode keeps one DerivedData folder per project path, and other repos can leave Clicky.app builds too.
# The build of this checkout wins, because several worktrees build at once and the newest build may be
# another branch's. Only when this checkout has no build does the newest build of any checkout count.
debug_app_path() {
  local checkout_project_paths this_checkout_project derived_data_folder newest_binary="" this_checkout_binary=""
  checkout_project_paths="$(git -C "$checkout_root" worktree list --porcelain | sed -n 's/^worktree //p' | sed 's#$#/leanring-buddy.xcodeproj#')"
  this_checkout_project="$checkout_root/leanring-buddy.xcodeproj"
  for derived_data_folder in "$HOME"/Library/Developer/Xcode/DerivedData/leanring-buddy-*; do
    local built_binary="$derived_data_folder/Build/Products/Debug/Clicky.app/Contents/MacOS/Clicky"
    [[ -f "$built_binary" ]] || continue
    local workspace_path
    workspace_path="$(plutil -extract WorkspacePath raw "$derived_data_folder/info.plist" 2>/dev/null || true)"
    grep -qxF "$workspace_path" <<<"$checkout_project_paths" || continue
    if [[ "$workspace_path" == "$this_checkout_project" ]] && [[ -z "$this_checkout_binary" || "$built_binary" -nt "$this_checkout_binary" ]]; then
      this_checkout_binary="$built_binary"
    fi
    if [[ -z "$newest_binary" || "$built_binary" -nt "$newest_binary" ]]; then
      newest_binary="$built_binary"
    fi
  done
  local chosen_binary="${this_checkout_binary:-$newest_binary}"
  [[ -n "$chosen_binary" ]] && echo "${chosen_binary%/Contents/MacOS/Clicky}"
  return 0
}

debug_app_workspace() {
  local app_path="$1"
  plutil -extract WorkspacePath raw "${app_path%/Build/Products/Debug/Clicky.app}/info.plist" 2>/dev/null || echo unknown
}

# The pattern starts at the command's first character, so a shell whose script text merely mentions the app's path
# (another agent's wait loop, for example) is not counted as a running Clicky.
running_clicky_pids() {
  pgrep -f '^/[^ ]*Clicky\.app/Contents/MacOS/Clicky( |$)' || true
}

descendant_pids() {
  local parent_pid="$1"
  local child_pid
  for child_pid in $(pgrep -P "$parent_pid" || true); do
    descendant_pids "$child_pid"
    echo "$child_pid"
  done
}

stop_process_tree() {
  local root_pid="$1"
  local tree_pids
  tree_pids="$(descendant_pids "$root_pid") $root_pid"
  # shellcheck disable=SC2086 # tree_pids is a list of numeric PIDs
  kill -TERM $tree_pids 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$root_pid" 2>/dev/null || return 0
    sleep 0.5
  done
  # shellcheck disable=SC2086
  kill -KILL $tree_pids 2>/dev/null || true
}

# Each launch's own files in a run, as "<name> <extension>" pairs: app.log becomes app-<N>.log, rehearsal-steps.txt
# becomes rehearsal-steps-<N>.txt, and so on.
per_launch_files=("app log" "app err" "app usage.log" "app rejections.log" "rehearsal-steps txt")

# Moves an earlier launch's files in this run to their <N> names, with N the first number no earlier launch used.
# `open --stdout` appends, so without this app-wait would match the earlier launch's "Live scene rehearsal: done" line
# and return before this launch's steps ran, and the permission check would read the earlier launch's start line. The
# usage, rejection, and steps files are rewritten on each launch, so they move too, and each launch keeps its evidence.
move_the_previous_launch_files_aside() {
  local run_dir="$1" launch_number=1 per_launch_file file_name file_extension slot_is_taken
  while :; do
    slot_is_taken=false
    for per_launch_file in "${per_launch_files[@]}"; do
      read -r file_name file_extension <<<"$per_launch_file"
      if [[ -e "$run_dir/$file_name-$launch_number.$file_extension" ]]; then slot_is_taken=true; fi
    done
    [[ "$slot_is_taken" == true ]] || break
    launch_number=$((launch_number + 1))
  done
  for per_launch_file in "${per_launch_files[@]}"; do
    read -r file_name file_extension <<<"$per_launch_file"
    if [[ -e "$run_dir/$file_name.$file_extension" ]]; then
      mv "$run_dir/$file_name.$file_extension" "$run_dir/$file_name-$launch_number.$file_extension"
    fi
  done
}

# The first Swift file under source_directory that is newer than dylib_path, or nothing when the app is at least as new
# as every Swift file. Only Swift code is linked into the dylib, so an edited page, script, or asset never makes it
# stale. A find error, such as a file deleted during the walk, counts as fresh, since the next build would not fix it.
first_source_newer_than() {
  local dylib_path="$1" source_directory="$2"
  find "$source_directory" -type f -name '*.swift' -newer "$dylib_path" -print -quit 2>/dev/null || true
}

# Builds the project in Xcode through AppleScript and prints Xcode's build status, such as "succeeded". Xcode's
# AppleScript build silently does nothing while a project has no active run destination, so this sets "My Mac" first.
run_xcode_build() {
  local project_path="$1"
  osascript - "$project_path" <<'APPLESCRIPT'
on run argv
  set projectPath to item 1 of argv
  tell application "Xcode"
    repeat 60 times
      if (count of (workspace documents whose path is projectPath)) > 0 then exit repeat
      delay 1
    end repeat
    set projectDocument to first workspace document whose path is projectPath
    repeat 60 times
      if loaded of projectDocument then exit repeat
      delay 1
    end repeat
    set active run destination of projectDocument to (first run destination of projectDocument whose name is "My Mac")
    set buildResult to build projectDocument
    repeat 900 times
      if completed of buildResult then exit repeat
      delay 1
    end repeat
    return status of buildResult as text
  end tell
end run
APPLESCRIPT
}

# Xcode's own build keeps Clicky's privacy grants, which xcodebuild resets. This builds, then checks the app changed and
# holds every Swift file under leanring-buddy/, the app target's only source folder.
command_build() {
  local project_path="$checkout_root/leanring-buddy.xcodeproj"
  local built_before=""
  local app_before
  app_before="$(debug_app_path)"
  if [[ -n "$app_before" && "$(debug_app_workspace "$app_before")" == "$project_path" ]]; then
    built_before="$(stat -f %m "$app_before/Contents/MacOS/Clicky.debug.dylib" 2>/dev/null || true)"
  fi
  open -a Xcode "$project_path"
  # Right after a checkout, Xcode can build from the files it had loaded before: the build fails, or it succeeds with
  # the previous checkout's code and nothing to compile. So a build counts only once the app is at least as new as
  # every Swift file, and Xcode gets a few seconds to notice the new files before each retry. An AppleScript error,
  # such as a project Xcode has not reloaded yet, counts as a failed try.
  local build_status app_after built_after stale_source attempt
  for attempt in 1 2 3; do
    build_status="$(run_xcode_build "$project_path")" || build_status="error"
    app_after="$(debug_app_path)"
    built_after=""
    stale_source=""
    if [[ -n "$app_after" && "$(debug_app_workspace "$app_after")" == "$project_path" ]]; then
      built_after="$(stat -f %m "$app_after/Contents/MacOS/Clicky.debug.dylib" 2>/dev/null || true)"
      if [[ -n "$built_after" ]]; then
        stale_source="$(first_source_newer_than "$app_after/Contents/MacOS/Clicky.debug.dylib" "$checkout_root/leanring-buddy")"
      fi
    fi
    if [[ "$build_status" == "succeeded" && -n "$built_after" && -z "$stale_source" ]]; then break; fi
    if (( attempt < 3 )); then
      echo "build: try $attempt ended with status ${build_status:-unknown}${stale_source:+ and $stale_source newer than the app}, so building again in 5 seconds" >&2
      sleep 5
    fi
  done
  if [[ "$build_status" == "error" ]]; then
    echo "The AppleScript build call failed 3 times for $project_path, so Xcode never built. Read the osascript errors above, and check that Xcode opened the project and that Automation lets this terminal control Xcode." >&2
    exit 1
  fi
  if [[ "$build_status" != "succeeded" ]]; then
    echo "Xcode build $build_status for $project_path after 3 tries. Read the errors in Xcode's issue navigator." >&2
    exit 1
  fi
  if [[ -z "$built_after" ]]; then
    echo "Xcode reported success, but no Debug app from $project_path exists. Check Xcode's scheme and destination." >&2
    exit 1
  fi
  if [[ -n "$stale_source" ]]; then
    echo "Xcode's last build succeeded, but $stale_source is newer than the app, so the app holds older code. Close the project in Xcode and build again." >&2
    exit 1
  fi
  if [[ "$built_after" == "$built_before" ]]; then
    echo "build: up to date, $app_after"
  else
    echo "build: done, $app_after"
  fi
}

# The app secret in a .dev.vars file, or nothing. Callers compare it and never print it.
dev_vars_app_secret() {
  grep -E '^CLICKY_APP_SECRET=' "$1" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true
}

# Says whether the Debug app's secret is missing, refused, or fine, without printing it. The harness brain calls the Worker's
# /v1/messages, which refuses a request without the secret in worker/.dev.vars. With no secret the app runs voice commands on
# the old Worker router from launch, and with a wrong one it re-sends the first command there and stays there. Args: the
# .dev.vars file, the Debug app's bundle ID (empty when it is not built), the last app log.
report_app_secret_state() {
  local dev_vars_file="$1" bundle_id="$2" app_log_file="$3"
  local worker_secret app_secret
  worker_secret="$(dev_vars_app_secret "$dev_vars_file")"
  if [[ -z "$worker_secret" ]]; then
    echo "app secret: worker/.dev.vars has no CLICKY_APP_SECRET, so the Worker refuses the harness's /v1/messages calls. Voice commands fall back to the old Worker router, and task agents and study guides fail. Copy it from the main checkout."
  elif [[ -z "$bundle_id" ]]; then
    echo "app secret: set in worker/.dev.vars. The Debug app is not built, so its defaults were not checked."
  else
    app_secret="$(defaults read "$bundle_id" clickyAppSecret 2>/dev/null || true)"
    if [[ -z "$app_secret" ]]; then
      echo "app secret: MISSING from the Debug app's defaults, so voice commands use the old Worker router and the harness gets 401 on every call. app-launch copies it from worker/.dev.vars."
    elif [[ "$app_secret" != "$worker_secret" ]]; then
      echo "app secret: REFUSED. The Debug app's secret differs from worker/.dev.vars, so the Worker answers 401 to the harness. The first voice command is re-sent on the old Worker router and later ones stay there. app-launch copies the right one."
    else
      echo "app secret: set in the Debug app's defaults, and the same as worker/.dev.vars"
    fi
  fi
  if [[ -f "$app_log_file" ]]; then
    if grep -q 'Brain: no app secret' "$app_log_file" 2>/dev/null; then
      echo "app secret: the last launch's log says it had no app secret"
    fi
    if grep -q 'the Worker refused the app secret' "$app_log_file" 2>/dev/null; then
      echo "app secret: the last launch's log says the Worker refused it"
    fi
  fi
}

# Copies the real secret into the Debug app's defaults before it starts, only in the default mode (copy). In none and wrong the
# app gets --app-secret-mode and acts as if the secret were missing or wrong, so the defaults, which the everyday Clicky
# shares, are never written or deleted. Args: the mode, the bundle ID, the real secret.
apply_app_secret_mode() {
  local mode="$1" bundle_id="$2" real_secret="$3"
  case "$mode" in
    copy)
      # .dev.vars may have none, and then the defaults keep what they hold.
      if [[ -n "$real_secret" ]]; then defaults write "$bundle_id" clickyAppSecret -string "$real_secret"; fi
      ;;
    none|wrong) ;;
    *) echo "unknown app secret mode $mode" >&2; return 1 ;;
  esac
  return 0
}

command_doctor() {
  echo "checkout: $checkout_root"
  echo "branch: $(git -C "$checkout_root" branch --show-current) at $(git -C "$checkout_root" log -1 --format='%h %s')"

  if [[ -f "$checkout_root/worker/.dev.vars" ]]; then
    # Print only names, so a malformed line never puts a key in the transcript.
    local key_names
    key_names="$(sed -n 's/^\(export \)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)=.*/\2/p' "$checkout_root/worker/.dev.vars" | paste -sd, -)"
    echo "worker/.dev.vars: present with ${key_names:-no KEY=value lines}"
  else
    echo "worker/.dev.vars: MISSING. Copy it from the main checkout before worker-up."
  fi

  local port
  for port in "$app_worker_port" "$default_own_worker_port"; do
    local listener_pid
    listener_pid="$(listener_pid_on_port "$port")"
    if [[ -z "$listener_pid" ]]; then
      echo "port $port: free"
      continue
    fi
    local owner="NOT started by this script. Do not stop or drive it"
    if worker_was_started_here "$port"; then
      owner="started by this script, log $(cat "$state_root/worker-$port.logpath")"
    fi
    echo "port $port: pid $listener_pid, $owner, serves $(worker_checkout_for_listener "$listener_pid")"
  done

  local app_path
  app_path="$(debug_app_path)"
  if [[ -z "$app_path" ]]; then
    echo "debug app: MISSING for this repository. Run this script's build command, which builds in Xcode. Never run xcodebuild locally."
  else
    local app_binary="$app_path/Contents/MacOS/Clicky"
    local build_epoch last_app_commit_epoch
    build_epoch="$(stat -f %m "$app_binary")"
    last_app_commit_epoch="$(git -C "$checkout_root" log -1 --format=%ct -- leanring-buddy leanring-buddy.xcodeproj)"
    echo "debug app: $app_path ($(plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist"))"
    echo "debug app built: $(date -r "$build_epoch" '+%Y-%m-%d %H:%M') from $(debug_app_workspace "$app_path")"
    if (( build_epoch < last_app_commit_epoch )); then
      echo "debug app: OLDER than the last app commit ($(git -C "$checkout_root" log -1 --format='%h %ci' -- leanring-buddy leanring-buddy.xcodeproj)). It may not match HEAD."
    fi
    local binaries_with_strings=()
    local candidate_binary
    for candidate_binary in "$app_path/Contents/MacOS/Clicky.debug.dylib" "$app_binary"; do
      [[ -f "$candidate_binary" ]] && binaries_with_strings+=("$candidate_binary")
    done
    if strings "${binaries_with_strings[@]}" | grep -x -- '--live-scene-rehearsal' >/dev/null; then
      echo "debug app: supports --live-scene-rehearsal"
    else
      echo "debug app: does NOT support --live-scene-rehearsal. Run this script's build command."
    fi
  fi

  report_app_secret_state "$checkout_root/worker/.dev.vars" "${app_path:+$(plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist")}" "$current_run_link/app.log"

  local clicky_pids our_app_id
  clicky_pids="$(running_clicky_pids | paste -sd, -)"
  our_app_id="$(recorded_process_id "$state_root/app.pid")"
  if [[ -z "$clicky_pids" ]]; then
    echo "clicky: not running"
  elif [[ -n "$our_app_id" && "$clicky_pids" == "$our_app_id" ]]; then
    echo "clicky: pid $clicky_pids, launched by this script"
  else
    echo "clicky: pid $clicky_pids, NOT launched by this script. Do not drive or quit it."
  fi

  if pgrep -xq 'Google Chrome'; then
    # The full URL can hold tokens, so print only the host and whether it is a YouTube video page.
    local front_tab_url front_tab_host
    front_tab_url="$(osascript -e 'tell application "Google Chrome" to get URL of active tab of front window' 2>/dev/null || true)"
    front_tab_host="$(sed -n 's#^[a-z]*://\([^/?#]*@\)\{0,1\}\([^/?#@]*\).*#\2#p' <<<"$front_tab_url")"
    if [[ "$front_tab_url" == *youtube.com/watch* ]]; then
      echo "chrome front tab: a YouTube video page"
    else
      echo "chrome front tab: ${front_tab_host:-unknown}, not a YouTube video page"
    fi
  else
    echo "chrome: not running"
  fi

  if [[ -d "$current_run_link" ]]; then echo "current run: $(readlink "$current_run_link")"; fi
}

command_worker_up() {
  local port="$default_own_worker_port"
  if [[ $# -gt 0 && "$1" != "--" ]]; then port="$1"; shift; fi
  if [[ $# -gt 0 && "$1" == "--" ]]; then shift; fi
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    echo "worker-up takes a numeric port first, then -- before wrangler args, as in: worker-up 8789 -- --var LIVE_SCENE_MODEL:sonnet" >&2
    exit 1
  fi
  if [[ -n "$(recorded_process_id "$state_root/worker-$port.pid")" ]]; then
    echo "a Worker this script started for port $port is still running. Run worker-down first." >&2
    exit 1
  fi
  if [[ -n "$(listener_pid_on_port "$port")" ]]; then
    echo "port $port is already in use by a process this script may not own. Run doctor." >&2
    exit 1
  fi
  if [[ ! -d "$checkout_root/worker/node_modules" ]]; then
    (cd "$checkout_root/worker" && pnpm install --frozen-lockfile)
  fi
  local run_dir worker_log
  run_dir="$(current_run_dir)"
  worker_log="$run_dir/worker-$port.log"
  local wrangler_root_id
  wrangler_root_id="$(cd "$checkout_root/worker" && { WRANGLER_SEND_METRICS=false nohup pnpm wrangler dev --port "$port" --ip 127.0.0.1 "$@" >"$worker_log" 2>&1 & echo $!; })"
  record_process "$wrangler_root_id" "$state_root/worker-$port.pid"
  echo "$worker_log" >"$state_root/worker-$port.logpath"
  # Any server can answer HTTP on a port, so ready also needs wrangler's own line and a listener in our process tree.
  for _ in $(seq 1 60); do
    if grep 'Ready on' "$worker_log" >/dev/null 2>&1 && worker_was_started_here "$port" && worker_answers_free_probe "$port"; then
      echo "worker ready on http://127.0.0.1:$port, log $worker_log"
      echo "It holds the API keys and spends them for any local caller, including web pages open in the browser, so stop it with cleanup when the run ends."
      return 0
    fi
    if ! kill -0 "$wrangler_root_id" 2>/dev/null; then
      echo "wrangler exited before it was ready. Log: $worker_log" >&2
      rm -f "$state_root/worker-$port.pid" "$state_root/worker-$port.logpath"
      exit 1
    fi
    sleep 1
  done
  echo "worker on port $port did not answer within 60 seconds. Log: $worker_log. Run cleanup." >&2
  exit 1
}

# With a port, stops only the Worker on that port, so a recipe can swap one Worker for a stub and keep another running.
command_worker_down() {
  local only_port="${1:-}"
  if [[ -n "$only_port" && ! "$only_port" =~ ^[0-9]+$ ]]; then
    echo "worker-down takes an optional numeric port, as in: worker-down 8787" >&2
    exit 1
  fi
  local record_file
  local record_pattern="worker-*.pid"
  [[ -n "$only_port" ]] && record_pattern="worker-$only_port.pid"
  for record_file in "$state_root"/$record_pattern; do
    [[ -f "$record_file" ]] || continue
    local port="${record_file##*/worker-}"
    port="${port%.pid}"
    local recorded_root_id
    recorded_root_id="$(recorded_process_id "$record_file")"
    if [[ -n "$recorded_root_id" ]]; then
      stop_process_tree "$recorded_root_id"
      echo "stopped the Worker this script started on port $port"
    else
      echo "the Worker recorded for port $port is no longer running, so nothing was stopped"
    fi
    rm -f "$record_file" "$state_root/worker-$port.logpath"
    local remaining_listener
    remaining_listener="$(listener_pid_on_port "$port")"
    if [[ -n "$remaining_listener" ]]; then
      echo "port $port is still held by pid $remaining_listener ($(worker_checkout_for_listener "$remaining_listener")). It is not stopped automatically. Tell Chris." >&2
    fi
  done
}

command_post() {
  local route="$1" body_file="$2" port="${3:-$default_own_worker_port}"
  if [[ "$route" != /* ]]; then echo "post needs a route that starts with /, as in /judge-answer" >&2; exit 1; fi
  if [[ ! -f "$body_file" ]]; then echo "no body file at $body_file" >&2; exit 1; fi
  if ! worker_was_started_here "$port"; then
    echo "No Worker this script started is listening on port $port. Run worker-up $port first, so the evidence comes from this checkout." >&2
    exit 1
  fi
  local run_dir response_file
  run_dir="$(current_run_dir)"
  response_file="$run_dir/response${route//\//-}-$(date +%H%M%S)-$RANDOM.json"
  local usage_from_line
  usage_from_line="$(worker_log_line_count "$port")"
  # The Notion routes and /v1/messages need the app's secret. It goes in a header file, so it never shows in the process list or the output.
  local secret_header_file="$run_dir/.app-secret-header"
  : >"$secret_header_file"
  chmod 600 "$secret_header_file"
  local app_secret
  app_secret="$(grep -E '^CLICKY_APP_SECRET=' "$checkout_root/worker/.dev.vars" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)"
  [[ -n "$app_secret" ]] && printf 'x-clicky-app-secret: %s\n' "$app_secret" >"$secret_header_file"
  local http_status curl_exit_code=0
  # The header file is removed once curl returns, failed or not, so a failed curl under set -e never leaves the secret behind.
  http_status="$(curl -sS -o "$response_file" -w '%{http_code}' -X POST "http://127.0.0.1:$port$route" \
    -H 'content-type: application/json' -H @"$secret_header_file" --data-binary @"$body_file" --max-time 180)" || curl_exit_code=$?
  rm -f "$secret_header_file"
  if [[ "$curl_exit_code" -ne 0 ]]; then
    echo "POST $route failed: curl exited with $curl_exit_code" >&2
    return "$curl_exit_code"
  fi
  echo "POST $route -> HTTP $http_status, body saved to $response_file"
  head -c 2000 "$response_file"
  echo
  report_usage_lines_since "$port" "$usage_from_line" "${response_file%.json}.usage.log"
  [[ "$http_status" == 2* ]]
}

# macOS keys privacy grants to the bundle ID, so a build with a new ID starts with none and every scene fails at screen capture.
require_screen_recording_grant() {
  local app_log="$1"
  for _ in $(seq 1 20); do
    if grep 'Clicky start' "$app_log" >/dev/null 2>&1; then
      grep 'Clicky start' "$app_log"
      if grep 'Clicky start.* screen: false' "$app_log" >/dev/null; then
        command_app_quit
        echo "This build has no Screen Recording grant. Ask Chris to allow Clicky in System Settings > Privacy & Security > Screen & System Audio Recording, and Accessibility for the video features, then launch again." >&2
        exit 1
      fi
      accessibility_grant_warning "$app_log" >&2
      return 0
    fi
    sleep 0.5
  done
  echo "warning: the app log has no 'Clicky start' permission line after 10 seconds" >&2
}

# The app opens its "Permissions needed" panel when any permission in the start line is missing or onboarding is not
# finished (`showPanelOnLaunch` in leanring_buddyApp.swift), and the panel covers a recorded take.
app_start_line_opens_the_permissions_panel() {
  local app_log="$1"
  grep -E 'Clicky start.*(accessibility|screen|mic|screenContent|onboarded): false' "$app_log" >/dev/null 2>&1
}

# The rehearsal runs without Accessibility, but push-to-talk, the settings dial, and Escape do not, and the app opens its
# "Permissions needed" panel, which covers a recorded take. macOS can drop the grant with no rebuild, so each launch checks.
accessibility_grant_warning() {
  local app_log="$1"
  if grep 'Clicky start.* accessibility: false' "$app_log" >/dev/null 2>&1; then
    echo "warning: this build has no Accessibility grant, so push-to-talk, the settings dial, and Escape do not work, and the app shows its permissions panel. Run this script's grant command and ask Chris to turn Clicky on there."
  fi
}

command_grant() {
  local app_path
  app_path="$(debug_app_path)"
  if [[ -z "$app_path" ]]; then
    echo "debug app: MISSING for this repository. Run this script's build command first." >&2
    exit 1
  fi
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  open -R "$app_path"
  echo "Opened Privacy & Security > Accessibility, and Finder shows the Debug app at $app_path."
  echo "Ask Chris to turn on Clicky in that list, or drag the Clicky.app Finder shows into it when Clicky is missing."
  echo "When Clicky's switch is already on and the app still logs 'accessibility: false', remove its row with the minus button and drag in the Clicky.app Finder shows."
  echo "The next app-launch prints 'accessibility: true' once the grant holds."
}

# Reads app-launch's flags into app_launch_flag_arguments, the app's own launch arguments for them (--no-app-secret and
# --wrong-app-secret become --app-secret-mode none|wrong), and the steps after them into app_launch_rehearsal_steps.
parse_app_launch_arguments() {
  app_launch_flag_arguments=()
  app_launch_needs_every_permission=false
  app_launch_app_secret_mode=copy
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-app-secret|--wrong-app-secret)
        local requested_mode=none
        if [[ "$1" == "--wrong-app-secret" ]]; then requested_mode=wrong; fi
        if [[ "$app_launch_app_secret_mode" != copy && "$app_launch_app_secret_mode" != "$requested_mode" ]]; then
          echo "--no-app-secret and --wrong-app-secret cannot go together" >&2
          exit 1
        fi
        # Without this guard a second flag would add a second --app-secret-mode argument.
        if [[ "$app_launch_app_secret_mode" == copy ]]; then
          app_launch_flag_arguments+=(--app-secret-mode "$requested_mode")
        fi
        app_launch_app_secret_mode="$requested_mode"
        ;;
      --brain) app_launch_flag_arguments+=(--brain-takes-every-request) ;;
      --harness-brain) app_launch_flag_arguments+=(--brain-runs-in-the-harness) ;;
      --every-permission) app_launch_needs_every_permission=true ;;
      --room-camera-file)
        app_launch_flag_arguments+=(--room-camera-file "${2:?--room-camera-file needs a video path}")
        shift
        ;;
      *) break ;;
    esac
    shift
  done
  app_launch_rehearsal_steps="${1:?rehearsal steps}"
}

command_app_launch() {
  parse_app_launch_arguments "$@"
  local rehearsal_steps="$app_launch_rehearsal_steps"
  local app_path
  app_path="$(debug_app_path)"
  if [[ -z "$app_path" ]]; then echo "No Debug Clicky.app built from this repository. Run this script's build command first." >&2; exit 1; fi
  if [[ -n "$(running_clicky_pids)" ]]; then
    echo "Clicky is already running (pid $(running_clicky_pids | paste -sd, -)). Two instances fight over the event tap and overlay. Ask Chris to quit his first." >&2
    exit 1
  fi
  if ! worker_was_started_here "$app_worker_port"; then
    echo "No Worker this script started is listening on 127.0.0.1:$app_worker_port, which the app calls. Run worker-up $app_worker_port when the port is free. When another process holds it, report the app surface as unverified." >&2
    exit 1
  fi
  local run_dir
  run_dir="$(current_run_dir)"
  move_the_previous_launch_files_aside "$run_dir"
  echo "$rehearsal_steps" >"$run_dir/rehearsal-steps.txt"
  worker_log_line_count "$app_worker_port" >"$state_root/app-usage-from-line"
  # The Worker's Notion routes and /v1/messages (the task agents and the voice command brain) need the app's secret, which
  # the app reads from its defaults. It is copied from .dev.vars without ever being printed, so a guide, a task page, or a
  # brain command works on the first launch. --no-app-secret and --wrong-app-secret leave the defaults alone, since the
  # everyday Clicky shares them, and pass the app --app-secret-mode, so an upgrade path that starts with no secret or a
  # refused one is on screen from the first command.
  local bundle_id
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
  apply_app_secret_mode "$app_launch_app_secret_mode" "$bundle_id" "$(dev_vars_app_secret "$checkout_root/worker/.dev.vars")"
  # NSUnbufferedIO makes Swift print() reach the log file line by line, as it does under Xcode.
  open -n "$app_path" --env NSUnbufferedIO=YES --stdout "$run_dir/app.log" --stderr "$run_dir/app.err" \
    --args --voice-tool-debug-server ${app_launch_flag_arguments[@]+"${app_launch_flag_arguments[@]}"} --live-scene-rehearsal "$rehearsal_steps"
  for _ in $(seq 1 20); do
    local launched_pid
    launched_pid="$(running_clicky_pids | head -1)"
    if [[ -n "$launched_pid" ]]; then
      record_process "$launched_pid" "$state_root/app.pid"
      echo "launched Clicky pid $launched_pid, log $run_dir/app.log"
      require_screen_recording_grant "$run_dir/app.log"
      if [[ "$app_launch_needs_every_permission" == true ]] && app_start_line_opens_the_permissions_panel "$run_dir/app.log"; then
        command_app_quit
        echo "The app started without every permission or onboarding, so it shows its permissions panel. The Clicky start line above names what is false: run this script's grant command for accessibility, ask Chris to allow the others under System Settings > Privacy & Security, or finish onboarding, then launch again." >&2
        exit 1
      fi
      return 0
    fi
    sleep 0.5
  done
  echo "Clicky did not start. See $run_dir/app.err" >&2
  exit 1
}

command_app_wait() {
  local timeout_seconds="${1:-240}"
  local app_log
  app_log="$(current_run_dir)/app.log"
  for _ in $(seq 1 "$timeout_seconds"); do
    if grep -q 'Live scene rehearsal: done' "$app_log" 2>/dev/null; then
      grep -E 'rehearsal|Live scene|Video quiz|Landmark|pop-out|Claude streaming request|⚠️|❌' "$app_log" || true
      report_usage_lines_since "$app_worker_port" "$(cat "$state_root/app-usage-from-line" 2>/dev/null || echo 0)" "$(current_run_dir)/app.usage.log"
      return 0
    fi
    if [[ -z "$(recorded_process_id "$state_root/app.pid")" ]]; then
      echo "Clicky exited before the rehearsal finished. Log: $app_log" >&2
      exit 1
    fi
    sleep 1
  done
  echo "No 'Live scene rehearsal: done' within $timeout_seconds seconds. Log: $app_log" >&2
  exit 1
}

command_app_quit() {
  local our_app_id
  our_app_id="$(recorded_process_id "$state_root/app.pid")"
  if [[ -n "$our_app_id" ]]; then
    stop_process_tree "$our_app_id"
    echo "quit the Clicky instance this script launched"
  fi
  rm -f "$state_root/app.pid"
}

# A real key event reaches the app's listen-only event tap, so this drives Escape and a push-to-talk tap.
# A tap holds ctrl+option briefly with nothing said, which the app treats as an interruption with no question.
command_key() {
  local key_name="$1"
  case "$key_name" in
    escape)
      osascript -e 'tell application "System Events" to key code 53'
      ;;
    push-to-talk-tap)
      osascript -e 'tell application "System Events"
        key down control
        key down option
        delay 0.3
        key up option
        key up control
      end tell'
      ;;
    dial-hold)
      osascript -e 'tell application "System Events"
        key down shift
        key down option
      end tell'
      ;;
    dial-release)
      osascript -e 'tell application "System Events"
        key up option
        key up shift
      end tell'
      ;;
    agents-list)
      # The Agents token sits 78 points from the dial's center at 54 degrees, which is 46 right and 63 down.
      local mouse_x mouse_y
      read -r mouse_x mouse_y < <(swift "$checkout_root/demo/scripts/mouse/mouse.swift" where)
      # A failed step below ends the script under set -e, which would leave shift and option held down on this Mac.
      trap 'osascript -e '"'"'tell application "System Events" to key up option'"'"' -e '"'"'tell application "System Events" to key up shift'"'"'' EXIT
      osascript -e 'tell application "System Events"
        key down shift
        key down option
      end tell'
      sleep 0.6
      swift "$checkout_root/demo/scripts/mouse/mouse.swift" move "$(awk -v x="$mouse_x" 'BEGIN { print x + 46 }')" "$(awk -v y="$mouse_y" 'BEGIN { print y + 63 }')" 0.3
      sleep 0.2
      osascript -e 'tell application "System Events"
        key up option
        key up shift
      end tell'
      # The list stays where the release opened it, and the mouse goes back, so a later glide starts where it always did.
      swift "$checkout_root/demo/scripts/mouse/mouse.swift" move "$mouse_x" "$mouse_y" 0.2
      ;;
    *)
      echo "key takes escape, push-to-talk-tap, dial-hold, dial-release, or agents-list" >&2
      exit 1
      ;;
  esac
  echo "pressed $key_name"
}

command_scroll() {
  local points="$1"
  # Six digits is far past any scroll area, and keeps scroll.swift's Int32 from overflowing when it negates the value.
  [[ "$points" =~ ^-?[0-9]{1,6}$ ]] || { echo "scroll takes a whole number of points up to 6 digits, positive to scroll down" >&2; exit 1; }
  swift "$checkout_root/.claude/skills/verify-clicky/scroll.swift" "$points"
  echo "scrolled $points points"
}

command_menu_icon() {
  case "$1" in
    status)
      grep 'Menu bar icon:' "$(current_run_dir)/app.log" 2>/dev/null | tail -1 || echo "no Menu bar icon line in the app log yet, the app logs it a second after launch" ;;
    click)
      # The status item's window can be missing from CGWindowList beside the notch, so the app clicks its own button.
      local click_reply
      click_reply="$(curl -sf -X POST http://127.0.0.1:8790/mcp -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"debug_click_menu_bar_icon","arguments":{}}}')" \
        || { echo "no app answered on 8790: launch it with app-launch first" >&2; exit 1; }
      if [[ "$click_reply" == *'"error"'* ]]; then echo "the app refused the click: $click_reply" >&2; exit 1; fi
      echo "clicked the menu bar icon" ;;
    *) echo "menu-icon takes status or click" >&2; exit 1 ;;
  esac
}

command_shot() {
  local shot_name="$1"
  local run_dir
  run_dir="$(current_run_dir)"
  # screencapture writes one file per display it was given a name for, so count displays the way it sees them.
  local display_count
  display_count="$(osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSScreen.screens.count' 2>/dev/null || true)"
  [[ "$display_count" =~ ^[1-9][0-9]*$ ]] || display_count=1
  local shot_files=()
  local display_index
  for display_index in $(seq 1 "$display_count"); do
    shot_files+=("$run_dir/$shot_name-display$display_index.png")
  done
  screencapture -x "${shot_files[@]}"
  printf 'saved %s\n' "${shot_files[@]}"
}

main() {
  local command_name="${1:-}"
  if [[ -z "$command_name" ]]; then usage; exit 0; fi
  shift
  if [[ "$command_name" != "doctor" ]]; then mkdir -p "$runs_root"; fi
  case "$command_name" in
    new-run) start_new_run "${1:?new-run needs a name}" ;;
    build) command_build ;;
    doctor) command_doctor ;;
    worker-up) command_worker_up "$@" ;;
    worker-down) command_worker_down "${1:-}" ;;
    post) command_post "${1:?route}" "${2:?body file}" "${3:-}" ;;
    app-launch) command_app_launch "$@" ;;
    app-wait) command_app_wait "${1:-240}" ;;
    app-quit) command_app_quit ;;
    shot) command_shot "${1:?shot name}" ;;
    scroll) command_scroll "${1:?points}" ;;
    menu-icon) command_menu_icon "${1:?status or click}" ;;
    key) command_key "${1:?key name}" ;;
    grant) command_grant ;;
    cleanup) command_app_quit; command_worker_down ;;
    *) usage; exit 1 ;;
  esac
}

# A test sources this file for its functions, so only a direct run dispatches a command.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
