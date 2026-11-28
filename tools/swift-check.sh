#!/usr/bin/env bash
# Builds the app's Swift sources and runs leanring-buddyTests without xcodebuild, which resets Clicky's
# privacy permissions on this Mac. It assembles a throwaway Swift package that links the sources in place.
# The package lives in a folder per checkout that later runs reuse.
# Each run deletes the folders of checkouts that are gone.
# It first runs tools/design-token-check.py, which fails on a font size or corner radius written outside DesignSystem.swift.
# Arguments pass through to `swift test`, such as --filter Voice.
set -euo pipefail

# The build uses every core, and several worktrees often check at once, which made the whole Mac slow.
# A nice value 10 higher than the caller's lets the apps in use run first.
# Every compile and test process this script starts inherits it.
renice -n 10 -p $$ >/dev/null

checkout_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

# Raw font sizes and corner radii fail here first, in a second, instead of after a compile. CI's bench job runs the same check.
python3 -I "$checkout_root/tools/design-token-check.py" "$checkout_root"

check_files="$checkout_root/tools/swift-check"
package_dir="${TMPDIR:-/tmp}/clicky-swift-check-$(printf '%s' "$checkout_root" | shasum | cut -c1-12)"

mkdir -p "$package_dir/Sources/Clicky" "$package_dir/Tests/ClickyTests"
# Names the checkout this folder belongs to, so a later run can tell when the checkout is gone.
# It is written before the cleanup, so a cleanup that another check runs at the same time keeps this folder.
printf '%s\n' "$checkout_root" > "$package_dir/.checkout-path"

# Delete the build folders of worktrees that are gone.
# A failed cleanup only costs disk space, so it never stops the check.
bash "$check_files/prune-build-folders.sh" "${TMPDIR:-/tmp}" "$package_dir" || echo "swift-check: could not remove old build folders" >&2
cp "$check_files/Package.swift" "$package_dir/Package.swift"

# Links are rebuilt each run, so a file added or deleted in the app shows up here too.
find "$package_dir/Sources/Clicky" "$package_dir/Tests/ClickyTests" -name '*.swift' -delete
for source_file in "$checkout_root"/leanring-buddy/*.swift; do
  # The app entry point has @main, which a library target cannot hold.
  [[ "$(basename "$source_file")" == "leanring_buddyApp.swift" ]] && continue
  ln -s "$source_file" "$package_dir/Sources/Clicky/"
done
for test_file in "$checkout_root"/leanring-buddyTests/*.swift; do
  ln -s "$test_file" "$package_dir/Tests/ClickyTests/"
done

# These tests read a page from the app bundle, which only exists when Xcode hosts the tests in Clicky.app,
# so they are skipped here. CI and Cmd+U still run them.
tests_that_need_the_app_bundle=(framePopoutPageCarriesWhetherThePictureShowsDepth framePopoutPageCarriesTheCursorColorForTheQuizLabel)
skip_arguments=()
for test_name in "${tests_that_need_the_app_bundle[@]}"; do
  skip_arguments+=(--skip "$test_name")
done
echo "swift-check: skipping ${#tests_that_need_the_app_bundle[@]} test(s) that need the app bundle: ${tests_that_need_the_app_bundle[*]}"

# The two Quick Look extensions (the preview and the thumbnail) each compile a few of the app's files on their own: the
# project's membership exception set for that target. Type-check each set alone with the extension's own sources, with
# flags that mirror the app's Swift settings in Package.swift (change all three together: the Xcode targets, Package.swift,
# and these flags), so a shared file that starts using an app-only type fails here instead of only in CI's Xcode build.
for extension_target in ClickyThemeQuickLook ClickyThemeThumbnail; do
  extension_files=()
  while IFS= read -r shared_file_name; do
    extension_files+=("$checkout_root/leanring-buddy/$shared_file_name")
  done < <(awk -v target="$extension_target" '
    index($0, "Exceptions for \"leanring-buddy\" folder in \"" target "\" target") && /= \{/ { in_set = 1 }
    in_set && /membershipExceptions = \(/ { in_list = 1; next }
    in_list && /\);/ { exit }
    in_list { gsub(/[\t ,]/, ""); if ($0 != "") print }
  ' "$checkout_root/leanring-buddy.xcodeproj/project.pbxproj")
  if [[ ${#extension_files[@]} -eq 0 ]]; then
    echo "swift-check: found no files for the $extension_target extension in project.pbxproj" >&2
    exit 1
  fi
  echo "swift-check: type-checking the $extension_target extension's ${#extension_files[@]} shared files on their own"
  swiftc -typecheck -parse-as-library -module-name "$extension_target" -target "$(uname -m)-apple-macos14.2" \
    -swift-version 5 -default-isolation MainActor -D DEBUG \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature MemberImportVisibility \
    "${extension_files[@]}" "$checkout_root/$extension_target"/*.swift
done

cd "$package_dir"
swift test "${skip_arguments[@]}" "$@"
