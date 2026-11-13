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
  doctor                    Health check of the Worker ports, the Debug app, and Chrome. Removes only PID records whose process is gone.
  worker-up [port] [-- wrangler args]
                            Start wrangler dev from this checkout (default port 8789).
                            Pass 8787 only when nothing listens there and the app must use it.
  worker-down               Stop the Workers this script started.
  post <route> <body.json> [port]
                            POST a JSON body to a Worker this script started, and save the response in the run.
  app-launch "<steps>"      Launch the Debug app with --live-scene-rehearsal "<steps>".
  app-wait [seconds]        Wait for "Live scene rehearsal: done" in the app log (default 240).
  app-quit                  Quit the app instance this script launched.
  shot <name>               Save a screenshot of every display into the run.
  key <escape|push-to-talk-tap>
                            Press that key through System Events, as the learner would, while the app runs.
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

running_clicky_pids() {
  pgrep -f 'Clicky.app/Contents/MacOS/Clicky' || true
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
    echo "debug app: MISSING for this repository. Chris builds it in Xcode (Cmd+B). Never run xcodebuild locally."
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
      echo "debug app: does NOT support --live-scene-rehearsal. Ask Chris to build in Xcode (Cmd+B)."
    fi
  fi

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

command_worker_down() {
  local record_file
  for record_file in "$state_root"/worker-*.pid; do
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
  local http_status
  http_status="$(curl -sS -o "$response_file" -w '%{http_code}' -X POST "http://127.0.0.1:$port$route" \
    -H 'content-type: application/json' --data-binary @"$body_file" --max-time 180)"
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
      return 0
    fi
    sleep 0.5
  done
  echo "warning: the app log has no 'Clicky start' permission line after 10 seconds" >&2
}

command_app_launch() {
  local rehearsal_steps="$1"
  local app_path
  app_path="$(debug_app_path)"
  if [[ -z "$app_path" ]]; then echo "No Debug Clicky.app built from this repository. Ask Chris to build in Xcode (Cmd+B)." >&2; exit 1; fi
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
  echo "$rehearsal_steps" >"$run_dir/rehearsal-steps.txt"
  worker_log_line_count "$app_worker_port" >"$state_root/app-usage-from-line"
  # NSUnbufferedIO makes Swift print() reach the log file line by line, as it does under Xcode.
  open -n "$app_path" --env NSUnbufferedIO=YES --stdout "$run_dir/app.log" --stderr "$run_dir/app.err" \
    --args --live-scene-rehearsal "$rehearsal_steps"
  for _ in $(seq 1 20); do
    local launched_pid
    launched_pid="$(running_clicky_pids | head -1)"
    if [[ -n "$launched_pid" ]]; then
      record_process "$launched_pid" "$state_root/app.pid"
      echo "launched Clicky pid $launched_pid, log $run_dir/app.log"
      require_screen_recording_grant "$run_dir/app.log"
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
    *)
      echo "key takes escape or push-to-talk-tap" >&2
      exit 1
      ;;
  esac
  echo "pressed $key_name"
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
    doctor) command_doctor ;;
    worker-up) command_worker_up "$@" ;;
    worker-down) command_worker_down ;;
    post) command_post "${1:?route}" "${2:?body file}" "${3:-}" ;;
    app-launch) command_app_launch "${1:?rehearsal steps}" ;;
    app-wait) command_app_wait "${1:-240}" ;;
    app-quit) command_app_quit ;;
    shot) command_shot "${1:?shot name}" ;;
    key) command_key "${1:?key name}" ;;
    cleanup) command_app_quit; command_worker_down ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
