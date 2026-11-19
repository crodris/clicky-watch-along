#!/usr/bin/env bash
# Builds the Go agent harness (harness/) as a universal macOS binary at
# Contents/Helpers/clicky-agent-harness inside the app bundle.
#
# Xcode runs this as the "Build Agent Harness" phase of the leanring-buddy target and sets SRCROOT, TARGET_BUILD_DIR,
# CONTENTS_FOLDER_PATH, and the code signing variables. To build by hand, set the first three:
#   SRCROOT="$PWD" TARGET_BUILD_DIR=/tmp/out CONTENTS_FOLDER_PATH=Clicky.app/Contents tools/build-agent-harness.sh
#
# The phase lists every harness/*.go file as an input, so a new Go source file must be added to that list in
# leanring-buddy.xcodeproj/project.pbxproj, or Xcode will not rebuild the harness when the file changes.
set -euo pipefail

source_root="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
helpers_directory="${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is not set}/${CONTENTS_FOLDER_PATH:?CONTENTS_FOLDER_PATH is not set}/Helpers"
harness_path="$helpers_directory/clicky-agent-harness"

# PATH comes first so a toolchain that CI or a developer put there wins. Xcode's PATH rarely holds Homebrew, so the
# usual install locations come next.
find_go() {
  if command -v go >/dev/null 2>&1; then
    command -v go
    return 0
  fi
  local candidate
  for candidate in /opt/homebrew/bin/go /usr/local/go/bin/go; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

if ! go_binary="$(find_go)"; then
  echo "error: Go is required to build the agent harness, and it was not found on PATH, in /opt/homebrew/bin, or in /usr/local/go/bin. Install it with 'brew install go' or from https://go.dev/dl/, then build again." >&2
  exit 1
fi

work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT

cd "$source_root/harness"
# Pure Go with no cgo, so each architecture cross-builds without a C toolchain. -mod=readonly keeps a build from
# rewriting go.mod or go.sum.
for architecture in arm64 amd64; do
  GOOS=darwin GOARCH="$architecture" CGO_ENABLED=0 GOFLAGS=-mod=readonly \
    "$go_binary" build -trimpath -ldflags "-s -w" -o "$work_directory/clicky-agent-harness-$architecture" .
done

mkdir -p "$helpers_directory"
lipo -create -output "$harness_path" "$work_directory/clicky-agent-harness-arm64" "$work_directory/clicky-agent-harness-amd64"

# lipo invalidates each slice's signature, and Apple Silicon refuses to run an unsigned binary. A signed build gets the
# app's identity with the hardened runtime, which notarization needs on every executable in the bundle.
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  if ! codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$harness_path"; then
    echo "warning: could not sign the agent harness with '$EXPANDED_CODE_SIGN_IDENTITY', so it is signed ad hoc. A notarized build needs the real signature." >&2
    codesign --force --sign - "$harness_path"
  fi
else
  codesign --force --sign - "$harness_path"
fi

echo "Built $harness_path ($(lipo -archs "$harness_path"))"
