#!/usr/bin/env bash
# Reads the changed file paths of a pull request or a push, one per line, on stdin, and prints "true" when the CI app
# job must run. The app job runs on the Mac runners, which are few and take one job each, so a change that touches
# nothing the Xcode build or its tests read skips it. The list names what is known to be outside the app, so a new
# top-level path runs it.
set -euo pipefail

# The second test keeps a last line that has no line break, which read reports as the end of input.
while IFS= read -r changed_file || [ -n "$changed_file" ]; do
  [ -z "$changed_file" ] && continue
  case "$changed_file" in
    bench/* | worker/* | demo/* | docs/* | .claude/* | .ship/* | tools/three-tiles/* | \
      README.md | AGENTS.md | CLAUDE.md | LICENSE | .gitignore | clicky-demo.gif) ;;
    *)
      echo "The app job runs, because $changed_file can change the app build or its tests." >&2
      echo true
      exit 0
      ;;
  esac
done

echo false
