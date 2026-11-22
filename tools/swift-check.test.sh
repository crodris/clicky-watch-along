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
  if [ ! -f "$scratch/$stand_in.nice" ]; then
    echo "FAIL: swift-check.sh never ran $stand_in"
    failures=$((failures + 1))
    continue
  fi
  actual_nice="$(cat "$scratch/$stand_in.nice")"
  if [ "$actual_nice" != "$expected_nice" ]; then
    echo "FAIL: $stand_in ran at nice $actual_nice, expected $expected_nice (the caller's $caller_nice plus 10)"
    failures=$((failures + 1))
  fi
done

# The build folder records its checkout, so the cleanup in a later run can tell when the checkout is gone.
checkout_root="$(git -C "$(dirname "$script")" rev-parse --show-toplevel)"
recorded_checkouts="$(cat "$scratch"/tmp/clicky-swift-check-*/.checkout-path 2>/dev/null || true)"
if [ "$recorded_checkouts" != "$checkout_root" ]; then
  echo "FAIL: the build folder recorded \"$recorded_checkouts\", expected \"$checkout_root\""
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  exit 1
fi
echo "swift-check.test.sh: swiftc and swift run at nice $expected_nice"
