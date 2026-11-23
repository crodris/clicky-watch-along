#!/usr/bin/env bash
# Pins which build folders tools/swift-check/prune-build-folders.sh removes, in a temporary TMPDIR of fake folders.
set -euo pipefail
script="$(cd "$(dirname "$0")" && pwd)/prune-build-folders.sh"
failures=0

scratch="$(mktemp -d)"
# A folder that loses its permissions below must get them back before the scratch folder can be removed.
trap 'chmod -R u+rwx "$scratch" 2>/dev/null; rm -rf "$scratch"' EXIT
temp_folder="$scratch/tmp"
live_checkout="$scratch/live-checkout"
mkdir -p "$temp_folder" "$live_checkout/.git"
# A worktree's .git is a file that points at the main checkout.
live_worktree="$scratch/live-worktree"
mkdir -p "$live_worktree"
echo "gitdir: $scratch/live-checkout/.git/worktrees/live-worktree" > "$live_worktree/.git"

# Makes a build folder with a file in it, as old as the given touch -t time, and with the given checkout record
# (or no record when the record argument is "none").
make_build_folder() {
  local folder_name="$1" age_stamp="$2" checkout_record="$3"
  local folder="$temp_folder/$folder_name"
  mkdir -p "$folder/.build"
  echo "object" > "$folder/.build/object.o"
  if [ "$checkout_record" != none ]; then
    echo "$checkout_record" > "$folder/.checkout-path"
  fi
  find "$folder" -exec touch -t "$age_stamp" {} +
}

two_days_ago="$(date -v-2d +%Y%m%d%H%M 2>/dev/null || date -d '2 days ago' +%Y%m%d%H%M)"
one_hour_ago="$(date -v-1H +%Y%m%d%H%M 2>/dev/null || date -d '1 hour ago' +%Y%m%d%H%M)"
now="$(date +%Y%m%d%H%M)"

expect_removed() {
  if [ -e "$temp_folder/$1" ]; then
    echo "FAIL: $2: $1 was not removed"
    failures=$((failures + 1))
  fi
}
expect_kept() {
  if [ ! -e "$temp_folder/$1" ]; then
    echo "FAIL: $2: $1 was removed"
    failures=$((failures + 1))
  fi
}

make_build_folder clicky-swift-check-aaaaaaaaaaaa "$two_days_ago" "$scratch/deleted-checkout"
make_build_folder clicky-swift-check-bbbbbbbbbbbb "$two_days_ago" "$live_checkout"
make_build_folder clicky-swift-check-ffffffffffff "$two_days_ago" "$live_worktree"
make_build_folder clicky-swift-check-444444444444 "$one_hour_ago" "$scratch/deleted-checkout"
# A folder whose size read and delete both fail, here through a subfolder with no permissions, is skipped.
# The folders after it are still removed. Its name sorts first, so the glob reaches it before the others.
make_build_folder clicky-swift-check-000000000000 "$two_days_ago" "$scratch/deleted-checkout"
chmod 000 "$temp_folder/clicky-swift-check-000000000000/.build"
make_build_folder clicky-swift-check-cccccccccccc "$now" "$scratch/deleted-checkout"
make_build_folder clicky-swift-check-dddddddddddd "$two_days_ago" none
make_build_folder clicky-swift-check-eeeeeeeeeeee "$one_hour_ago" none
make_build_folder clicky-swift-check-111111111111 "$two_days_ago" "$scratch/deleted-checkout"
make_build_folder clicky-swift-check-abc "$two_days_ago" "$scratch/deleted-checkout"
make_build_folder clicky-swift-check-ABCDEFABCDEF "$two_days_ago" "$scratch/deleted-checkout"
make_build_folder clicky-swift-check-aaaaaaaaaaaaaa "$two_days_ago" "$scratch/deleted-checkout"
make_build_folder other-folder "$two_days_ago" none
# A checkout folder that exists but lost its .git entry is gone too.
mkdir -p "$scratch/no-git-checkout"
make_build_folder clicky-swift-check-222222222222 "$two_days_ago" "$scratch/no-git-checkout"
# The run's own folder stays even when its record names a gone checkout and it is old.
make_build_folder clicky-swift-check-999999999999 "$two_days_ago" "$scratch/deleted-checkout"
# A symbolic link with a matching name is never followed or removed.
mkdir -p "$scratch/link-target"
ln -s "$scratch/link-target" "$temp_folder/clicky-swift-check-333333333333"
touch -h -t "$two_days_ago" "$temp_folder/clicky-swift-check-333333333333"

output="$(bash "$script" "$temp_folder" "$temp_folder/clicky-swift-check-999999999999")"

expect_removed clicky-swift-check-aaaaaaaaaaaa "a gone checkout's folder"
expect_kept clicky-swift-check-bbbbbbbbbbbb "a live checkout's folder"
expect_kept clicky-swift-check-ffffffffffff "a live worktree's folder, whose .git is a file"
expect_removed clicky-swift-check-444444444444 "a gone checkout's folder changed an hour ago"
expect_kept clicky-swift-check-000000000000 "a folder whose delete failed"
expect_kept clicky-swift-check-cccccccccccc "a recent folder of a gone checkout"
expect_removed clicky-swift-check-dddddddddddd "an old folder with no record"
expect_kept clicky-swift-check-eeeeeeeeeeee "a folder with no record changed an hour ago"
expect_removed clicky-swift-check-111111111111 "a name of only digits, which are hex digits"
expect_kept clicky-swift-check-abc "a name with too few hex digits"
expect_kept clicky-swift-check-ABCDEFABCDEF "a name with upper case digits"
expect_kept clicky-swift-check-aaaaaaaaaaaaaa "a name with too many hex digits"
expect_kept other-folder "a name that does not match"
expect_removed clicky-swift-check-222222222222 "a checkout with no .git entry"
expect_kept clicky-swift-check-999999999999 "this run's own folder"
expect_kept clicky-swift-check-333333333333 "a symbolic link"
if [ ! -e "$scratch/link-target" ]; then
  echo "FAIL: a symbolic link's target was removed"
  failures=$((failures + 1))
fi
if [[ "$output" != "swift-check: removed 5 build folders of checkouts that are gone ("*")" ]]; then
  echo "FAIL: the log line: got \"$output\""
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  exit 1
fi
echo "prune-build-folders.test.sh: all cases pass"
