#!/usr/bin/env bash
# Builds the app's Swift sources and runs leanring-buddyTests without xcodebuild, which resets Clicky's
# privacy permissions on this Mac. It assembles a throwaway Swift package that links the sources in place.
# Arguments pass through to `swift test`, such as --filter Voice.
set -euo pipefail

checkout_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
check_files="$checkout_root/tools/swift-check"
package_dir="${TMPDIR:-/tmp}/clicky-swift-check-$(printf '%s' "$checkout_root" | shasum | cut -c1-12)"

mkdir -p "$package_dir/Sources/Clicky" "$package_dir/Tests/ClickyTests"
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

# The Quick Look extension compiles a few of the app's files on their own: the project's membership exception set for the
# ClickyThemeQuickLook target. Type-check that set alone, with the app's Swift settings from Package.swift, so a shared file
# that starts using an app-only type fails here instead of only in CI's Xcode build.
quick_look_files=()
while IFS= read -r shared_file_name; do
  quick_look_files+=("$checkout_root/leanring-buddy/$shared_file_name")
done < <(awk '
  /Exceptions for "leanring-buddy" folder in "ClickyThemeQuickLook" target/ && /= \{/ { in_set = 1 }
  in_set && /membershipExceptions = \(/ { in_list = 1; next }
  in_list && /\);/ { exit }
  in_list { gsub(/[\t ,]/, ""); if ($0 != "") print }
' "$checkout_root/leanring-buddy.xcodeproj/project.pbxproj")
if [[ ${#quick_look_files[@]} -eq 0 ]]; then
  echo "swift-check: found no files for the Quick Look extension in project.pbxproj" >&2
  exit 1
fi
echo "swift-check: type-checking the Quick Look extension's ${#quick_look_files[@]} shared files on their own"
swiftc -typecheck -parse-as-library -module-name ClickyThemeQuickLook -target "$(uname -m)-apple-macos14.2" \
  -swift-version 5 -default-isolation MainActor -D DEBUG \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature MemberImportVisibility \
  "${quick_look_files[@]}" "$checkout_root"/ClickyThemeQuickLook/*.swift

cd "$package_dir"
swift test "${skip_arguments[@]}" "$@"
