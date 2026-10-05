#!/bin/bash
# Runs Relay's built-in checks (crypto test vectors, request signatures, Tailscale parsing, …).
# Builds a debug binary and runs it with --self-test, which exits before any listener, hook
# or UI starts, so it is safe while Relay itself is running.
#   scripts/selftest.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Compiling (debug)"
set +e
swift build 2>&1 | grep -vE "search path .* not found"
STATUS=${PIPESTATUS[0]}
set -e
[ "$STATUS" -eq 0 ] || { echo "build failed (swift build exit $STATUS)"; exit 1; }
BIN="$(swift build --show-bin-path)/Relay"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

echo "==> Running self-tests"
exec "$BIN" --self-test
