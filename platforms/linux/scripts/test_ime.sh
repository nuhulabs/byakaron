#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Run the IME integration test against a throwaway engine process.
#
#     bash platforms/linux/scripts/test_ime.sh
#
# Starts byakaron-ibus registered with the running ibus-daemon, drives it
# through a private input context, then shuts it down again. The desktop's own
# input source is never touched.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd)"

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
ZIG="${ZIG_EXE:-$(command -v zig || true)}"
[[ -n "$ZIG" ]] || { echo "error: no 'zig' on PATH" >&2; exit 1; }

if ! pgrep -x ibus-daemon >/dev/null; then
    echo "error: ibus-daemon is not running — start it with 'ibus-daemon -drx'" >&2
    exit 1
fi

echo ">>> Building engine and test..."
( cd "$REPO_ROOT" && "$ZIG" build linux linux-test -Doptimize="${ZIG_OPTIMIZE:-ReleaseFast}" )

BIN="$REPO_ROOT/zig-out/bin/byakaron-ibus"
TEST_BIN="$REPO_ROOT/zig-out/bin/byakaron-ime-test"
XML="$PROJECT_ROOT/build/byakaron.xml"

mkdir -p "$PROJECT_ROOT/build"
sed -e "s|@BYK_EXEC@|$BIN|g" -e "s|@BYK_ICON@|input-keyboard|g" \
    "$PROJECT_ROOT/Resources/byakaron.xml.in" > "$XML"

ENGINE_PID=""
cleanup() {
    if [[ -n "$ENGINE_PID" ]] && kill -0 "$ENGINE_PID" 2>/dev/null; then
        kill "$ENGINE_PID" 2>/dev/null || true
        wait "$ENGINE_PID" 2>/dev/null || true
        echo ">>> Engine stopped"
    fi
}
trap cleanup EXIT

echo ">>> Starting engine..."
"$BIN" --xml "$XML" &
ENGINE_PID=$!

# Give the daemon a moment to accept the component registration.
for _ in $(seq 1 30); do
    kill -0 "$ENGINE_PID" 2>/dev/null || { echo "error: engine exited early" >&2; exit 1; }
    sleep 0.2
done

echo ">>> Running integration test..."
echo
"$TEST_BIN"
STATUS=$?

if [[ $STATUS -eq 77 ]]; then
    echo "note: test skipped — the engine was not reachable" >&2
fi
exit $STATUS
