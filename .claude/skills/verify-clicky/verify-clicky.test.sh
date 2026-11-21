#!/bin/bash
# Checks first_source_newer_than, which tells `build` that Xcode built from older files, such as right after a checkout,
# running_clicky_pids, which `app-launch` uses to refuse a second Clicky, and move_the_previous_launch_files_aside, which keeps
# an earlier launch's log lines away from app-wait.
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
# A second launch in the same run must not leave the first launch's lines where app-wait reads.
run_directory="$test_directory/run"
mkdir -p "$run_directory"
echo "Live scene rehearsal: done" >"$run_directory/app.log"
echo "first launch" >"$run_directory/app.err"
move_the_previous_launch_files_aside "$run_directory"
check "an earlier launch's log moves aside" "$(cat "$run_directory/app-1.log")" "Live scene rehearsal: done"
check "an earlier launch's error log moves aside" "$(cat "$run_directory/app-1.err")" "first launch"
check "the next launch starts with no app.log" "$([[ -e "$run_directory/app.log" ]] && echo present || echo absent)" "absent"
echo "second launch" >"$run_directory/app.log"
move_the_previous_launch_files_aside "$run_directory"
check "a third launch keeps the second launch's log under the next number" "$(cat "$run_directory/app-2.log")" "second launch"
# The usage, rejection, and steps files are rewritten on each launch, so they move with the log under the same number.
echo "third launch" >"$run_directory/app.log"
echo "steps" >"$run_directory/rehearsal-steps.txt"
echo "usage" >"$run_directory/app.usage.log"
echo "rejected" >"$run_directory/app.rejections.log"
move_the_previous_launch_files_aside "$run_directory"
check "the steps move with their launch's log" "$(cat "$run_directory/rehearsal-steps-3.txt")" "steps"
check "the usage lines move with their launch's log" "$(cat "$run_directory/app-3.usage.log")" "usage"
check "the rejections move with their launch's log" "$(cat "$run_directory/app-3.rejections.log")" "rejected"
# A number an earlier launch used for any one of its files is taken, even when its log is gone.
other_run_directory="$test_directory/other-run"
mkdir -p "$other_run_directory"
echo "earlier errors" >"$other_run_directory/app-1.err"
echo "fourth launch" >"$other_run_directory/app.log"
move_the_previous_launch_files_aside "$other_run_directory"
check "a number with only an error log is taken" "$(cat "$other_run_directory/app-2.log")" "fourth launch"
check "the earlier error log is left alone" "$(cat "$other_run_directory/app-1.err")" "earlier errors"
# A leftover steps file alone also takes its number, so a later launch never overwrites it.
steps_run_directory="$test_directory/steps-run"
mkdir -p "$steps_run_directory"
echo "earlier steps" >"$steps_run_directory/rehearsal-steps-1.txt"
echo "fifth launch" >"$steps_run_directory/app.log"
echo "fifth steps" >"$steps_run_directory/rehearsal-steps.txt"
move_the_previous_launch_files_aside "$steps_run_directory"
check "a number with only a steps file is taken" "$(cat "$steps_run_directory/app-2.log")" "fifth launch"
check "the earlier steps file is left alone" "$(cat "$steps_run_directory/rehearsal-steps-1.txt")" "earlier steps"
echo "ok: verify-clicky build freshness, running-app detection, and app log rotation"
