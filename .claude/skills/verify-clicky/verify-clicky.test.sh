#!/bin/bash
# Checks first_source_newer_than, which tells `build` that Xcode built from older files, such as right after a checkout,
# running_clicky_pids, which `app-launch` uses to refuse a second Clicky, and parse_app_launch_arguments, which reads
# `app-launch`'s flags, and command_worker_down, which stops one Worker when given its port.
# Usage: bash .claude/skills/verify-clicky/verify-clicky.test.sh
set -euo pipefail
source "$(dirname "$0")/verify-clicky.sh"

test_directory="$(mktemp -d)"
# The fake processes below stay alive until killed, so a failed check must not leave them running.
fake_process_ids=""
trap 'kill $fake_process_ids 2>/dev/null || true; chmod -R u+rwx "$test_directory"; rm -rf "$test_directory"' EXIT
mkdir -p "$test_directory/sources"
dylib_path="$test_directory/Clicky.debug.dylib"
touch -t 202601010000 "$test_directory/sources/StudyGuide.swift"
touch -t 202601020000 "$dylib_path"

check() {
  local description="$1" actual_value="$2" expected_value="$3"
  [[ "$actual_value" == "$expected_value" ]] || {
    echo "FAIL: $description"
    echo "  want: '$expected_value'"
    echo "  got:  '$actual_value'"
    exit 1
  }
}

state_root="$test_directory/state"
mkdir -p "$state_root"
# Two Worker records whose processes are gone, so worker-down only removes the records.
echo 999999 >"$state_root/worker-8787.pid"
echo 999999 >"$state_root/worker-8788.pid"
command_worker_down 8787 >/dev/null 2>&1
check "worker-down with a port leaves the other Worker's record" "$(ls "$state_root" | tr '\n' ' ')" "worker-8788.pid "
command_worker_down >/dev/null 2>&1
check "worker-down with no port removes every Worker's record" "$(ls "$state_root" | tr '\n' ' ')" ""

check "an app newer than every source is current" "$(first_source_newer_than "$dylib_path" "$test_directory/sources")" ""
touch -t 202601030000 "$test_directory/sources/frame-popout.html"
check "a newer page that is not linked into the app is not stale" \
  "$(first_source_newer_than "$dylib_path" "$test_directory/sources")" ""
touch -t 202601030000 "$test_directory/sources/StudyGuide.swift"
check "a Swift file checked out after the build makes the app stale" \
  "$(first_source_newer_than "$dylib_path" "$test_directory/sources")" "$test_directory/sources/StudyGuide.swift"
# A folder find cannot read must not end the build script, which assigns the result under set -e as this does.
mkdir "$test_directory/unreadable" && chmod 000 "$test_directory/unreadable"
stale_source="$(first_source_newer_than "$dylib_path" "$test_directory/unreadable")"
check "a find error counts as fresh" "$stale_source" ""
# A shell whose script text only mentions the app's path is not a running Clicky, and a process started from the binary is.
# The fake app is sleep run under the binary's path as its argv[0], so its command line starts with that path, as the real app's does.
fake_app_path="$test_directory/Clicky.app/Contents/MacOS/Clicky"
# The loop keeps bash from replacing itself with sleep, which would drop the path from its command line.
bash -c "while :; do sleep 1; done # $fake_app_path" &
mentioning_shell_id=$!
fake_process_ids="$mentioning_shell_id"
sleep 0.5
check "a shell that only mentions the app's path is not a running Clicky" "$(running_clicky_pids | grep -cx "$mentioning_shell_id" || true)" "0"
bash -c "exec -a '$fake_app_path' sleep 30" &
fake_app_id=$!
fake_process_ids="$fake_process_ids $fake_app_id"
sleep 0.5
# A real Clicky on this Mac is listed too, so the check looks for the fake app's id among the ids.
check "a process started from the app's binary is a running Clicky" "$(running_clicky_pids | grep -cx "$fake_app_id" || true)" "1"
# app-launch's flags become the app's launch arguments in either order, and the steps follow them.
parse_app_launch_arguments --harness-brain --brain "turn it to the left|^pause it"
check "both brain flags pass their launch arguments" "${app_launch_flag_arguments[*]}" "--brain-runs-in-the-harness --brain-takes-every-request"
check "the steps follow the flags" "$app_launch_rehearsal_steps" "turn it to the left|^pause it"
parse_app_launch_arguments "pop this out"
check "no flag passes no launch argument" "${#app_launch_flag_arguments[@]}" "0"
echo "ok: verify-clicky build freshness, running-app detection, and app-launch flags"
