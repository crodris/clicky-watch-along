#!/usr/bin/env bash
# Builds the app's Swift sources and runs leanring-buddyTests without xcodebuild, which resets Clicky's
# privacy permissions on this Mac. It assembles a throwaway Swift package that links the sources in place,
# with stand-ins for PostHog and Sparkle. Arguments pass through to `swift test`, such as --filter Voice.
set -euo pipefail

checkout_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
check_files="$checkout_root/tools/swift-check"
package_dir="${TMPDIR:-/tmp}/clicky-swift-check-$(printf '%s' "$checkout_root" | shasum | cut -c1-12)"

mkdir -p "$package_dir/Sources/PostHog" "$package_dir/Sources/Sparkle" "$package_dir/Sources/Clicky" "$package_dir/Tests/ClickyTests"
cp "$check_files/Package.swift" "$package_dir/Package.swift"
cp "$check_files/PostHog.swift" "$package_dir/Sources/PostHog/PostHog.swift"
cp "$check_files/Sparkle.swift" "$package_dir/Sources/Sparkle/Sparkle.swift"

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

cd "$package_dir"
swift test "$@"
