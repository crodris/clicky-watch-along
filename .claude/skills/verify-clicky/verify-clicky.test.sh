#!/bin/bash
# Checks first_source_newer_than, which tells `build` that Xcode built from older files, such as right after a checkout,
# and running_clicky_pids, which `app-launch` uses to refuse a second Clicky.
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
echo "ok: verify-clicky build freshness and running-app detection"
