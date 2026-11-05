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
  doctor                    Read-only health check of the Worker, the Debug app, and Chrome.
  worker-up [port] [-- wrangler args]
                            Start wrangler dev from this checkout (default port 8789).
                            Pass 8787 only when nothing listens there and the app must use it.
  worker-down               Stop the Worker this script started.
  post <route> <body.json> [port]
                            POST a JSON body to the Worker and save the response in the run.
  app-launch "<steps>"      Launch the Debug app with --live-scene-rehearsal "<steps>".
  app-wait [seconds]        Wait for "Live scene rehearsal: done" in the app log (default 240).
  app-quit                  Quit the app instance this script launched.
  shot <name>               Save a screenshot of every display into the run.
  cleanup                   app-quit and worker-down. Evidence stays in .verify-clicky/runs.
EOF
}

current_run_dir() {
  if [[ ! -L "$current_run_link" ]]; then
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
  local listener_pid our_tree
  listener_pid="$(listener_pid_on_port "$port")"
  [[ -n "$listener_pid" && -f "$state_root/worker-$port.pid" ]] || return 1
  our_tree="$(descendant_pids "$(cat "$state_root/worker-$port.pid")")"
  grep -qx "$listener_pid" <<<"$our_tree"
}

worker_log_line_count() {
  local port="$1"
  if [[ -f "$state_root/worker-$port.logpath" ]]; then
    wc -l <"$(cat "$state_root/worker-$port.logpath")" | tr -d ' '
  else
    echo 0
  fi
}

# Prints the "[/route] usage {...}" lines the Worker logged after line <from_line>, and saves them to <output_file>.
# One line per model attempt, so two lines for one request mean one retry.
report_usage_lines_since() {
  local port="$1" from_line="$2" output_file="$3"
  if [[ ! -f "$state_root/worker-$port.logpath" ]]; then
    echo "usage lines: unavailable, the Worker on port $port was not started by this script"
    return 0
  fi
  sleep 1
  tail -n +"$((from_line + 1))" "$(cat "$state_root/worker-$port.logpath")" | grep -E '^\[/[a-z-]+\] usage ' >"$output_file" || true
  local usage_line
  while IFS= read -r usage_line; do
    local route_name="${usage_line%% usage *}"
    echo "$route_name $(jq -c '{input_tokens, cache_read_input_tokens, output_tokens, thinking_tokens: .output_tokens_details.thinking_tokens}' <<<"${usage_line#* usage }")"
  done <"$output_file"
  echo "usage lines: $(wc -l <"$output_file" | tr -d ' '), saved to $output_file"
}

# Xcode can leave several DerivedData folders, so pick the app whose executable was built last.
debug_app_path() {
  local newest_binary
  newest_binary="$(ls -t "$HOME"/Library/Developer/Xcode/DerivedData/leanring-buddy-*/Build/Products/Debug/Clicky.app/Contents/MacOS/Clicky 2>/dev/null | head -1 || true)"
  [[ -n "$newest_binary" ]] && echo "${newest_binary%/Contents/MacOS/Clicky}"
  return 0
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
  kill -TERM $tree_pids 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$root_pid" 2>/dev/null || return 0
    sleep 0.5
  done
  kill -KILL $tree_pids 2>/dev/null || true
}

command_doctor() {
  echo "checkout: $checkout_root"
  echo "branch: $(git -C "$checkout_root" branch --show-current) at $(git -C "$checkout_root" log -1 --format='%h %s')"

  if [[ -f "$checkout_root/worker/.dev.vars" ]]; then
    echo "worker/.dev.vars: present with $(cut -d= -f1 "$checkout_root/worker/.dev.vars" | paste -sd, -)"
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
    local owner="not started by this script"
    if worker_was_started_here "$port"; then
      owner="started by this script, log $(cat "$state_root/worker-$port.logpath")"
    fi
    local health="does NOT answer the free probe"
    if worker_answers_free_probe "$port"; then health="answers the free probe"; fi
    echo "port $port: pid $listener_pid, $owner, serves $(worker_checkout_for_listener "$listener_pid"), $health"
  done

  local app_path
  app_path="$(debug_app_path)"
  if [[ -z "$app_path" ]]; then
    echo "debug app: MISSING. Chris builds it in Xcode (Cmd+B). Never run xcodebuild locally."
  else
    local app_binary="$app_path/Contents/MacOS/Clicky"
    local build_epoch last_app_commit_epoch
    build_epoch="$(stat -f %m "$app_binary")"
    last_app_commit_epoch="$(git -C "$checkout_root" log -1 --format=%ct -- leanring-buddy leanring-buddy.xcodeproj)"
    echo "debug app: $app_path ($(plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist"))"
    echo "debug app built: $(date -r "$build_epoch" '+%Y-%m-%d %H:%M')"
    if (( build_epoch < last_app_commit_epoch )); then
      echo "debug app: OLDER than the last app commit ($(git -C "$checkout_root" log -1 --format='%h %ci' -- leanring-buddy leanring-buddy.xcodeproj)). It may not match HEAD."
    fi
    if strings "$app_path/Contents/MacOS/Clicky.debug.dylib" "$app_binary" 2>/dev/null | grep -x -- '--live-scene-rehearsal' >/dev/null; then
      echo "debug app: supports --live-scene-rehearsal"
    else
      echo "debug app: does NOT support --live-scene-rehearsal. Ask Chris to build in Xcode (Cmd+B)."
    fi
  fi

  local clicky_pids
  clicky_pids="$(running_clicky_pids | paste -sd, -)"
  if [[ -z "$clicky_pids" ]]; then
    echo "clicky: not running"
  elif [[ -f "$state_root/app.pid" ]] && [[ "$clicky_pids" == "$(cat "$state_root/app.pid")" ]]; then
    echo "clicky: pid $clicky_pids, launched by this script"
  else
    echo "clicky: pid $clicky_pids, NOT launched by this script. Do not drive or quit it."
  fi

  if pgrep -xq 'Google Chrome'; then
    echo "chrome front tab: $(osascript -e 'tell application "Google Chrome" to get URL of active tab of front window' 2>/dev/null || echo unknown)"
  else
    echo "chrome: not running"
  fi

  if [[ -L "$current_run_link" ]]; then echo "current run: $(readlink "$current_run_link")"; fi
}

command_worker_up() {
  local port="$default_own_worker_port"
  if [[ $# -gt 0 && "$1" != "--" ]]; then port="$1"; shift; fi
  if [[ $# -gt 0 && "$1" == "--" ]]; then shift; fi
  if [[ -n "$(listener_pid_on_port "$port")" ]]; then
    echo "port $port is already in use. Run doctor, and reuse that Worker only if it serves the checkout you are verifying." >&2
    exit 1
  fi
  if [[ ! -d "$checkout_root/worker/node_modules" ]]; then
    (cd "$checkout_root/worker" && pnpm install --frozen-lockfile)
  fi
  local run_dir worker_log
  run_dir="$(current_run_dir)"
  worker_log="$run_dir/worker-$port.log"
  (cd "$checkout_root/worker" && WRANGLER_SEND_METRICS=false nohup pnpm wrangler dev --port "$port" --ip 127.0.0.1 "$@" >"$worker_log" 2>&1 &
    echo $! >"$state_root/worker-$port.pid")
  echo "$worker_log" >"$state_root/worker-$port.logpath"
  # Any server can answer HTTP on a port, so ready also needs wrangler's own line and a listener in our process tree.
  for _ in $(seq 1 60); do
    if grep 'Ready on' "$worker_log" >/dev/null 2>&1 && worker_was_started_here "$port" && worker_answers_free_probe "$port"; then
      echo "worker ready on http://127.0.0.1:$port, log $worker_log"
      return 0
    fi
    if ! kill -0 "$(cat "$state_root/worker-$port.pid")" 2>/dev/null; then
      echo "wrangler exited before it was ready. Log: $worker_log" >&2
      rm -f "$state_root/worker-$port.pid" "$state_root/worker-$port.logpath"
      exit 1
    fi
    sleep 1
  done
  echo "worker on port $port did not answer within 60 seconds. Log: $worker_log" >&2
  exit 1
}

command_worker_down() {
  local pid_file
  for pid_file in "$state_root"/worker-*.pid; do
    [[ -f "$pid_file" ]] || continue
    stop_process_tree "$(cat "$pid_file")"
    rm -f "$pid_file" "${pid_file%.pid}.logpath"
    echo "stopped worker from $(basename "$pid_file")"
  done
}

command_post() {
  local route="$1" body_file="$2" port="${3:-$default_own_worker_port}"
  local run_dir response_file
  run_dir="$(current_run_dir)"
  response_file="$run_dir/response${route//\//-}-$(date +%H%M%S).json"
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
  if [[ -z "$app_path" ]]; then echo "No Debug Clicky.app. Ask Chris to build in Xcode (Cmd+B)." >&2; exit 1; fi
  if [[ -n "$(running_clicky_pids)" ]]; then
    echo "Clicky is already running (pid $(running_clicky_pids | paste -sd, -)). Two instances fight over the event tap and overlay. Ask Chris to quit his first." >&2
    exit 1
  fi
  if ! worker_answers_free_probe "$app_worker_port"; then
    echo "Nothing healthy on 127.0.0.1:$app_worker_port, which the app calls. Run worker-up $app_worker_port if the port is free." >&2
    exit 1
  fi
  if ! worker_was_started_here "$app_worker_port"; then
    echo "warning: the Worker on port $app_worker_port was not started by this script, so this run captures no usage lines." >&2
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
      echo "$launched_pid" >"$state_root/app.pid"
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
      grep -E 'rehearsal|Live scene|Video quiz|Landmark|pop-out|⚠️|❌' "$app_log" || true
      report_usage_lines_since "$app_worker_port" "$(cat "$state_root/app-usage-from-line" 2>/dev/null || echo 0)" "$(current_run_dir)/app.usage.log"
      return 0
    fi
    if [[ -f "$state_root/app.pid" ]] && ! kill -0 "$(cat "$state_root/app.pid")" 2>/dev/null; then
      echo "Clicky exited before the rehearsal finished. Log: $app_log" >&2
      exit 1
    fi
    sleep 1
  done
  echo "No 'Live scene rehearsal: done' within $timeout_seconds seconds. Log: $app_log" >&2
  exit 1
}

command_app_quit() {
  if [[ -f "$state_root/app.pid" ]]; then
    stop_process_tree "$(cat "$state_root/app.pid")"
    rm -f "$state_root/app.pid"
    echo "quit the Clicky instance this script launched"
  fi
}

command_shot() {
  local shot_name="$1"
  local run_dir
  run_dir="$(current_run_dir)"
  local display_count
  display_count="$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c 'Resolution:' || echo 1)"
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
  mkdir -p "$runs_root"
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
    cleanup) command_app_quit; command_worker_down ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
