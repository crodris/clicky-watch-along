#!/usr/bin/env bash
# Deletes the build folders that tools/swift-check.sh left behind for checkouts that are gone.
# Usage: prune-build-folders.sh <temp folder> <this run's own build folder>
#
# swift-check.sh builds in <temp folder>/clicky-swift-check-<12 hex digits>, one folder per checkout.
# It keeps the folder, so a second check in the same checkout compiles only what changed.
# Agents make many short-lived worktrees, so the folders of deleted worktrees accumulate (95 folders, 38 GB, on 2026-11-22).
# A folder is removed when:
#   - its .checkout-path file names a folder that no longer exists or no longer has a .git entry, or
#   - it has no .checkout-path file (an older run made it) and nothing in it changed in the last day.
# A folder with anything changed in the last 15 minutes always stays, since a check in another checkout may be running.
# This run's own folder and every name that is not exactly clicky-swift-check- plus 12 hex digits also stay.
set -euo pipefail

usage="usage: prune-build-folders.sh <temp folder> <own build folder of this run>"
temp_folder="${1:?$usage}"
own_build_folder="${2:?$usage}"
own_build_folder_name="$(basename "$own_build_folder")"

minutes_a_running_check_keeps_a_folder_fresh=15
minutes_in_a_day=1440

removed_folder_count=0
removed_kilobytes=0

for build_folder in "$temp_folder"/clicky-swift-check-*; do
  [[ -d "$build_folder" && ! -L "$build_folder" ]] || continue
  build_folder_name="$(basename "$build_folder")"
  [[ "$build_folder_name" =~ ^clicky-swift-check-[0-9a-f]{12}$ ]] || continue
  [[ "$build_folder_name" == "$own_build_folder_name" ]] && continue

  # The record is checked first, so a live checkout's folder is never walked.
  checkout_record="$build_folder/.checkout-path"
  if [[ -f "$checkout_record" ]]; then
    recorded_checkout_path="$(head -n 1 "$checkout_record")" || continue
    # A worktree's .git is a file and a clone's is a folder, so -e accepts both, and a folder that is gone has neither.
    if [[ -e "$recorded_checkout_path/.git" ]]; then
      continue
    fi
    minutes_that_keep_the_folder=$minutes_a_running_check_keeps_a_folder_fresh
  else
    minutes_that_keep_the_folder=$minutes_in_a_day
  fi

  # find -mmin -N matches an entry changed less than N minutes ago, and -quit stops at the first match.
  # A subfolder it cannot read is only skipped, so its error is not shown.
  if [[ -n "$(find "$build_folder" -mmin "-$minutes_that_keep_the_folder" -print -quit 2>/dev/null)" ]]; then
    continue
  fi

  # Another check's prune may delete the same folder at the same time.
  # So a failed size read counts as 0.
  # A failed delete skips the folder instead of ending the prune.
  folder_kilobytes="$(du -sk "$build_folder" 2>/dev/null | cut -f1)" || folder_kilobytes=0
  rm -rf "$build_folder" 2>/dev/null || continue
  removed_folder_count=$((removed_folder_count + 1))
  removed_kilobytes=$((removed_kilobytes + folder_kilobytes))
done

if [[ "$removed_folder_count" -gt 0 ]]; then
  removed_size="$(awk -v kilobytes="$removed_kilobytes" 'BEGIN { printf "%.1f GB", kilobytes / 1048576 }')"
  echo "swift-check: removed $removed_folder_count build folders of checkouts that are gone ($removed_size)"
fi
