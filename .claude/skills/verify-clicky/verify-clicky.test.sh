#!/bin/bash
# Checks first_source_newer_than, which tells `build` that Xcode built from older files, such as right after a checkout,
# running_clicky_pids, which `app-launch` uses to refuse a second Clicky, parse_app_launch_arguments, which reads
# `app-launch`'s flags, command_worker_down, which stops one Worker when given its port,
# move_the_previous_launch_files_aside, which keeps an earlier launch's log lines away from app-wait,
# accessibility_grant_warning, which tells app-launch to name the grant command, copy_app_secret_to_defaults and
# report_app_secret_state, which app-launch and doctor use for the app secret the voice command brain needs, and the scroll
# command's usage line and refusal of a value that is not a whole number of at most 6 digits, headless_chrome_warning,
# which doctor and app-launch use to name a headless Chrome that takes Chrome's Apple Events, and the lock-take and
# lock-release commands of the app check lock, which refuse to release a lock another owner holds.
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

printf '%s\n' "Clicky start — accessibility: false, screen: true, mic: true" >"$test_directory/no-accessibility.log"
printf '%s\n' "Clicky start — accessibility: true, screen: true, mic: true" >"$test_directory/accessibility.log"
check "a launch without Accessibility warns and names the grant command" \
  "$(accessibility_grant_warning "$test_directory/no-accessibility.log" | grep -o 'grant command')" "grant command"
check "a launch with Accessibility prints no warning" "$(accessibility_grant_warning "$test_directory/accessibility.log")" ""
check "app-launch's permission check prints the warning for a launch without Accessibility" \
  "$(require_screen_recording_grant "$test_directory/no-accessibility.log" 2>&1 | grep -o 'grant command')" "grant command"
for missing_permission in accessibility screen mic screenContent onboarded; do
  printf '%s\n' "Clicky start — accessibility: true, screen: true, mic: true, screenContent: true, onboarded: true" \
    | sed "s/ $missing_permission: true/ $missing_permission: false/" >"$test_directory/missing-$missing_permission.log"
  check "a start line without $missing_permission opens the permissions panel" \
    "$(app_start_line_opens_the_permissions_panel "$test_directory/missing-$missing_permission.log" && echo opens)" "opens"
done
printf '%s\n' "Clicky start — accessibility: true, screen: true, mic: true, screenContent: true, onboarded: true" >"$test_directory/every-permission.log"
check "a start line with every permission opens no panel" \
  "$(app_start_line_opens_the_permissions_panel "$test_directory/every-permission.log" && echo opens || true)" ""
parse_app_launch_arguments --every-permission "pop this out"
check "--every-permission is a check, not an app argument" "${#app_launch_flag_arguments[@]} $app_launch_needs_every_permission" "0 true"

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
# A Clicky run by another user, such as a CI test host under clicky-ci, cannot touch this user's event tap, so it does not block
# a launch. This test cannot start a process as another user, so a stand-in pgrep lists one unless the lookup asks for this
# user's processes with -U, and always lists one of this user's.
other_user_clicky_id=424242
this_user_clicky_id=434343
pgrep() {
  local lookup_is_limited_to_this_user=false
  [[ " $* " == *" -U $(id -u) "* ]] && lookup_is_limited_to_this_user=true
  [[ "$lookup_is_limited_to_this_user" == false ]] && echo "$other_user_clicky_id"
  echo "$this_user_clicky_id"
}
check "a Clicky run by another user is not a running Clicky" "$(running_clicky_pids | grep -cx "$other_user_clicky_id" || true)" "0"
check "a Clicky run by this user is a running Clicky" "$(running_clicky_pids | grep -cx "$this_user_clicky_id" || true)" "1"
unset -f pgrep
# app-launch's flags become the app's launch arguments in either order, and the steps follow them.
parse_app_launch_arguments --brain "turn it to the left|^pause it"
check "--brain passes its launch argument" "${app_launch_flag_arguments[*]}" "--brain-takes-every-request"
check "the steps follow the flags" "$app_launch_rehearsal_steps" "turn it to the left|^pause it"
parse_app_launch_arguments --show-setup "+30 thanks"
check "--show-setup passes its launch argument and keeps the steps" "${app_launch_flag_arguments[*]} $app_launch_rehearsal_steps" "--show-setup +30 thanks"
parse_app_launch_arguments "pop this out"
check "no flag passes no launch argument" "${#app_launch_flag_arguments[@]}" "0"
check "the app calls the Worker on 8787 by default" "$app_launch_worker_port" "8787"
parse_app_launch_arguments --worker-port 8796 --no-speculation "%turn it left"
check "--worker-port and --no-speculation pass their launch arguments" "${app_launch_flag_arguments[*]}" "--worker-port 8796 --no-voice-command-speculation"
check "--worker-port sets the port app-launch checks" "$app_launch_worker_port" "8796"
check "the steps follow the port" "$app_launch_rehearsal_steps" "%turn it left"
port_error="$( (parse_app_launch_arguments --worker-port eighty "x") 2>&1)" || true
check "--worker-port refuses a value that is not a port" "$port_error" "--worker-port takes a port number from 1024 to 65535, as in: --worker-port 8796"
# The app falls back to 8787 below 1024 and above 65535, so the script refuses those too.
for out_of_range_port in 1023 65536 99999; do
  range_error="$( (parse_app_launch_arguments --worker-port "$out_of_range_port" "x") 2>&1)" || true
  check "--worker-port refuses $out_of_range_port" "$range_error" "--worker-port takes a port number from 1024 to 65535, as in: --worker-port 8796"
done
parse_app_launch_arguments --worker-port 65535 "x"
check "--worker-port takes the highest port" "$app_launch_worker_port" "65535"
parse_app_launch_arguments --worker-port 1024 "x"
check "--worker-port takes the lowest port" "$app_launch_worker_port" "1024"
parse_app_launch_arguments --room-camera-file /tmp/pan.mp4 --brain "how would this look in my room"
check "--room-camera-file passes the video path and keeps the other flags" "${app_launch_flag_arguments[*]}|$app_launch_rehearsal_steps" "--room-camera-file /tmp/pan.mp4 --brain-takes-every-request|how would this look in my room"

# The defaults command is shadowed, so these checks write nothing to this Mac's defaults.
defaults_calls_file="$test_directory/defaults-calls.txt"
fake_defaults_secret=""
defaults() {
  case "$1" in
    read) [[ -n "$fake_defaults_secret" ]] && echo "$fake_defaults_secret" || return 1 ;;
    *) printf '%s\n' "$*" >>"$defaults_calls_file" ;;
  esac
}
: >"$defaults_calls_file"
copy_app_secret_to_defaults com.example.clicky real-secret
check "app-launch copies the real secret" "$(cat "$defaults_calls_file")" "write com.example.clicky clickyAppSecret -string real-secret"
: >"$defaults_calls_file"
copy_app_secret_to_defaults com.example.clicky ""
check "app-launch writes nothing when .dev.vars has no secret" "$(cat "$defaults_calls_file")" ""

# doctor says whether the secret is missing, refused, or fine, and never prints it.
printf 'ANTHROPIC_API_KEY=sk-x\nCLICKY_APP_SECRET="real-secret"\n' >"$test_directory/dev-vars-with-secret"
printf 'ANTHROPIC_API_KEY=sk-x\n' >"$test_directory/dev-vars-without-secret"
fake_defaults_secret=""
secret_report="$(report_app_secret_state "$test_directory/dev-vars-with-secret" com.example.clicky "$test_directory/no-such-log")"
check "doctor reports a secret missing from the Debug app's defaults" "$(grep -c '^app secret: MISSING' <<<"$secret_report")" "1"
fake_defaults_secret="some-other-secret"
secret_report="$(report_app_secret_state "$test_directory/dev-vars-with-secret" com.example.clicky "$test_directory/no-such-log")"
check "doctor reports a secret the Worker refuses" "$(grep -c '^app secret: REFUSED' <<<"$secret_report")" "1"
fake_defaults_secret="real-secret"
secret_report="$(report_app_secret_state "$test_directory/dev-vars-with-secret" com.example.clicky "$test_directory/no-such-log")"
check "doctor reports a matching secret" "$(grep -c "^app secret: set in the Debug app's defaults, and the same" <<<"$secret_report")" "1"
check "doctor never prints a secret" "$(grep -c -e 'real-secret' -e 'some-other-secret' <<<"$secret_report" || true)" "0"
secret_report="$(report_app_secret_state "$test_directory/dev-vars-without-secret" com.example.clicky "$test_directory/no-such-log")"
check "doctor reports a .dev.vars with no secret" "$(grep -c 'has no CLICKY_APP_SECRET' <<<"$secret_report")" "1"
printf '%s\n' "Voice command: the router failed, so its fallback takes it: app secret refused" >"$test_directory/refused.log"
secret_report="$(report_app_secret_state "$test_directory/dev-vars-with-secret" com.example.clicky "$test_directory/refused.log")"
check "doctor reports a refusal the last launch's log recorded" "$(grep -c "last launch's log says the Worker refused it" <<<"$secret_report")" "1"
unset -f defaults

# The usage text is how a driver learns the scroll primitive, and a bad value must stop before any event is posted.
check "usage lists the scroll command" "$(usage | grep -c 'scroll <points>')" "1"
# The function exits on a bad value, which ends only the command substitution, so its failure status is tolerated outside it.
scroll_error="$(command_scroll "not-a-number" 2>&1)" || true
scroll_refusal="scroll takes a whole number of points up to 6 digits, positive to scroll down"
check "scroll refuses a value that is not a whole number" "$scroll_error" "$scroll_refusal"
# Int32.min passes Int32(...) but traps when scroll.swift negates it, so the digit cap must stop it here.
scroll_error="$(command_scroll "-2147483648" 2>&1)" || true
check "scroll refuses a value of more than 6 digits" "$scroll_error" "$scroll_refusal"
scroll_error="$(command_scroll "1000000" 2>&1)" || true
check "scroll refuses a positive value of 7 digits" "$scroll_error" "$scroll_refusal"
# The menu bar icon's window can be missing from the window list, so a driver clicks it through the app. Its usage must say so.
check "usage lists the menu-icon command" "$(usage | grep -c 'menu-icon <status|click>')" "1"
menu_icon_error="$(command_menu_icon "sideways" 2>&1)" || true
check "menu-icon refuses an unknown action" "$menu_icon_error" "menu-icon takes status or click"
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
# A headless Chrome answers the Apple Events meant for Chris's Chrome and fails them as "turned off", which agents misread
# as his setting. Doctor and app-launch name it. A Chrome with a window and a headless Chrome's helpers are not named.
orphan_headless_line="83128     1 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new --remote-debugging-port=0 --user-data-dir=/var/folders/ab/T/scene-shots-9XaGV9/chrome-profile about:blank"
helper_line="83177 83128 /Applications/Google Chrome.app/Contents/Frameworks/Helpers/Google Chrome Helper --type=gpu-process --headless --user-data-dir=/var/folders/ab/T/scene-shots-9XaGV9/chrome-profile"
chris_chrome_line="35023     1 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
headless_warning="$(headless_chrome_warning "$chris_chrome_line"$'\n'"$orphan_headless_line"$'\n'"$helper_line")"
check "a headless Chrome is named with its pid and profile" \
  "$(grep -c 'pid 83128, orphaned.*profile /var/folders/ab/T/scene-shots-9XaGV9/chrome-profile' <<<"$headless_warning")" "1"
check "the warning says Apple Events go to it and that the error is not Chris's setting" \
  "$(grep -c 'Apple Events to Chrome go to it.*turned off' <<<"$headless_warning")" "1"
check "the warning says how to stop a scene screenshot orphan" "$(grep -c 'kill 83128' <<<"$headless_warning")" "1"
# Another tool's headless Chrome can also have launchd as its parent while it is in use, so it gets no kill command.
other_tool_headless_line="90001     1 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new --user-data-dir=/Users/c/playwright/profile"
other_tool_warning="$(headless_chrome_warning "$other_tool_headless_line")"
check "a headless Chrome of another tool is named" "$(grep -c 'pid 90001' <<<"$other_tool_warning")" "1"
check "a headless Chrome of another tool gets no kill command" "$(grep -c 'kill 90001' <<<"$other_tool_warning" || true)" "0"
check "a headless Chrome's helper processes are not named again" "$(grep -c 'pid 83177' <<<"$headless_warning")" "0"
check "Chris's own Chrome with a window gets no warning" "$(headless_chrome_warning "$chris_chrome_line")" ""
check "a headless Chrome with a live parent is not called an orphan" \
  "$(headless_chrome_warning "${orphan_headless_line/    1 /5000 }" | grep -c 'pid 83128, orphaned' || true)" "0"
for command_with_the_warning in command_doctor command_app_launch; do
  check "$command_with_the_warning reports a headless Chrome" "$(declare -f "$command_with_the_warning" | grep -c report_headless_chrome)" "1"
done
check "app-launch warns before it opens the app" \
  "$(declare -f command_app_launch | grep -n 'report_headless_chrome\|open -n' | cut -d: -f2 | grep -o 'report_headless_chrome\|open -n' | head -1)" "report_headless_chrome"

# The app check lock: one owner at a time, and only that owner releases it.
export CLICKY_APP_CHECK_LOCK="$test_directory/app-check.lock"
check "usage lists the lock commands" "$(usage | grep -c 'lock-take <owner>\|lock-release <owner>')" "2"
lock_output="$(command_lock_take "feature/first" 2>&1)"
check "lock-take takes a free lock for its owner" "$lock_output" "app check lock taken by feature/first"
check "lock-take writes the owner on the first line and the time on the second" \
  "$(sed -n 1p "$CLICKY_APP_CHECK_LOCK/owner") $(sed -n 2p "$CLICKY_APP_CHECK_LOCK/owner" | grep -c "^[0-9]*$")" "feature/first 1"
lock_status=0
lock_output="$(command_lock_take "feature/second" 2>&1)" || lock_status=$?
check "lock-take fails while another owner holds the lock" "$lock_status" "1"
check "lock-take names the real owner and says not to remove it" "$(grep -c 'held by feature/first for [0-9]* minutes.*Do not remove it' <<<"$lock_output")" "1"
check "lock-take says how long the lock has been held, from the time it recorded" \
  "$(printf 'feature/first\n%s\n' "$(( $(date +%s) - 1500 ))" >"$CLICKY_APP_CHECK_LOCK/owner"; (command_lock_take "feature/second" 2>&1 || true) | grep -c 'for 25 minutes')" "1"
printf 'feature/first\n' >"$CLICKY_APP_CHECK_LOCK/owner"
check "a failed lock-take leaves the owner alone" "$(sed -n 1p "$CLICKY_APP_CHECK_LOCK/owner")" "feature/first"
check "lock-take by the owner again succeeds" "$(command_lock_take "feature/first" 2>&1)" "app check lock already held by feature/first"
lock_status=0
lock_output="$(command_lock_release "feature/second" 2>&1)" || lock_status=$?
check "lock-release refuses another owner's lock" "$lock_status" "1"
check "lock-release names the real owner" "$(grep -c 'held by feature/first, not by feature/second' <<<"$lock_output")" "1"
check "a refused lock-release leaves the lock in place" "$([[ -d "$CLICKY_APP_CHECK_LOCK" ]] && echo held || echo gone)" "held"
check "lock-release by the owner removes the lock" "$(command_lock_release "feature/first" 2>&1)" "app check lock released by feature/first"
check "the released lock is gone" "$([[ -d "$CLICKY_APP_CHECK_LOCK" ]] && echo held || echo gone)" "gone"
check "lock-release with no lock held is not an error" "$(command_lock_release "feature/first" 2>&1)" "no app check lock is held"
check "the next owner can take the released lock" "$(command_lock_take "feature/second" 2>&1)" "app check lock taken by feature/second"
# A lock directory with no owner file belongs to nobody who can be named, so no one's release removes it.
rm "$CLICKY_APP_CHECK_LOCK/owner"
lock_status=0
lock_output="$(command_lock_release "feature/second" 2>&1)" || lock_status=$?
check "lock-release refuses a lock with no owner file" "$lock_status" "1"
check "that refusal says the owner did not write its name" "$(grep -c 'an owner that did not write its name' <<<"$lock_output")" "1"
rm -r "$CLICKY_APP_CHECK_LOCK"
lock_status=0
(command_lock_take "") >/dev/null 2>&1 || lock_status=$?
check "lock-take needs an owner name" "$lock_status" "1"
check "the missing-name refusal takes no lock" "$([[ -d "$CLICKY_APP_CHECK_LOCK" ]] && echo held || echo gone)" "gone"
# A lock whose owner could not be written would belong to no one and could never be released, so it is not left behind.
lock_status=0
lock_output="$(printf() { return 1; }; command_lock_take "feature/third" 2>&1)" || lock_status=$?
check "lock-take fails when it cannot write the owner" "$lock_status" "1"
check "lock-take leaves no lock behind when it cannot write the owner" "$([[ -d "$CLICKY_APP_CHECK_LOCK" ]] && echo held || echo gone)" "gone"
unset CLICKY_APP_CHECK_LOCK
echo "ok: verify-clicky build freshness, running-app detection, app-launch flags and the app secret copy, the doctor secret report, app log rotation, the Accessibility warning and the permissions panel check, scroll usage and argument checks, the headless Chrome warning, and the app check lock"
