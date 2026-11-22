#!/usr/bin/env bash
# Pins that tools/swift-check.sh builds and tests at a lower CPU priority than its caller.
# Stand-ins for swiftc and swift record the nice value they run at, so no Swift build runs.
set -euo pipefail
script="$(cd "$(dirname "$0")" && pwd)/swift-check.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

mkdir "$scratch/bin" "$scratch/tmp"
for stand_in in swift swiftc; do
  cat > "$scratch/bin/$stand_in" <<EOF
#!/usr/bin/env bash
ps -o nice= -p \$\$ | tr -d ' ' > "$scratch/$stand_in.nice"
EOF
  chmod +x "$scratch/bin/$stand_in"
done

# TMPDIR keeps the script's package folder in the scratch folder, away from a real check's build folder.
PATH="$scratch/bin:$PATH" TMPDIR="$scratch/tmp" bash "$script" > /dev/null

caller_nice="$(ps -o nice= -p $$ | tr -d ' ')"
expected_nice=$((caller_nice + 10 > 20 ? 20 : caller_nice + 10))
failures=0
for stand_in in swiftc swift; do
  actual_nice="$(cat "$scratch/$stand_in.nice")"
  if [ "$actual_nice" != "$expected_nice" ]; then
    echo "FAIL: $stand_in ran at nice $actual_nice, expected $expected_nice (the caller's $caller_nice plus 10)"
    failures=$((failures + 1))
  fi
done

if [ "$failures" -gt 0 ]; then
  exit 1
fi
echo "swift-check.test.sh: swiftc and swift run at nice $expected_nice"
