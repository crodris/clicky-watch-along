#!/usr/bin/env bash
# Pins which changed paths make tools/app-job-needed.sh run the CI app job.
set -euo pipefail
script="$(cd "$(dirname "$0")" && pwd)/app-job-needed.sh"
failures=0

expect() {
  local expected="$1" description="$2" changed_files="$3"
  local actual
  actual="$(printf '%s' "$changed_files" | bash "$script" 2>/dev/null)"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $description: expected $expected, got $actual"
    failures=$((failures + 1))
  fi
}

expect false "a bench-only change" $'bench/brainEvals.ts\nbench/fixtures/brain-evals.json'
expect false "a worker and docs change" $'worker/src/index.ts\ndocs/plans/theme-studio.md\nAGENTS.md'
expect false "no changed files" ''
expect true "a Swift source" 'leanring-buddy/CompanionManager.swift'
expect true "a bundled skill, which is Markdown inside the app" 'leanring-buddy/Skills/flashcards.md'
expect true "the harness, which the app bundles" 'harness/brain.go'
expect true "the harness test fixture a Swift test reads" 'harness/testdata/approval-voice-answers.json'
expect true "the workflow itself" '.github/workflows/ci.yml'
expect true "this script" 'tools/app-job-needed.sh'
expect true "one app file among skipped ones" $'bench/bench.ts\nleanring-buddy.xcodeproj/project.pbxproj\nworker/src/index.ts'

if [ "$failures" -gt 0 ]; then
  exit 1
fi
echo "app-job-needed.test.sh: all cases pass"
