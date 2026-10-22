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

if [[ -z "${BYAKARON_SPELL_DB:-}" && -f "$REPO_ROOT/packages/data/spell.db" ]]; then
    export BYAKARON_SPELL_DB="$REPO_ROOT/packages/data/spell.db"
fi

# Default settings, not the desktop's: the user's own choices (Bangla digits
# off, say) would otherwise change what the engine types and fail the test.
export GSETTINGS_BACKEND=memory

# A throwaway personal dictionary: the test writes to it while the engine runs,
# the way the app does, and never touches the user's real one.
export BYAKARON_USER_DICT="$PROJECT_ROOT/build/ime-test-user-words.txt"
# Not empty at start: reading an existing file at engine start is what once
# crashed (a stat() struct mismatch under Zig's libc headers).
printf 'আমায়\n' > "$BYAKARON_USER_DICT"
# And a throwaway learned-words file, empty at start.
export BYAKARON_LEARNED="$PROJECT_ROOT/build/ime-test-learned-words.txt"
rm -f "$BYAKARON_LEARNED"

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
sed -e "s|@BYK_EXEC@|$BIN|g" \
    -e "s|@BYK_ICON@|input-keyboard|g" \
    -e "s|@BYK_SETUP@||g" \
    "$PROJECT_ROOT/Resources/byakaron.xml.in" > "$XML"

# Focusing the test's input context makes the daemon adopt its engine as the
# session's global one, so killing the throwaway engine afterwards would leave
# the desktop with "No global engine" and no way to type. Remember what was
# active and put it back no matter how this script exits.
PREV_ENGINE="$(ibus engine 2>/dev/null || true)"
case "$PREV_ENGINE" in
    *"No engine"* | "") PREV_ENGINE="" ;;
esac

ENGINE_PID=""
cleanup() {
    if [[ -n "$ENGINE_PID" ]] && kill -0 "$ENGINE_PID" 2>/dev/null; then
        kill "$ENGINE_PID" 2>/dev/null || true
        wait "$ENGINE_PID" 2>/dev/null || true
        echo ">>> Engine stopped"
    fi
    if [[ -n "$PREV_ENGINE" ]] && [[ "$(ibus engine 2>/dev/null || true)" != "$PREV_ENGINE" ]]; then
        ibus engine "$PREV_ENGINE" 2>/dev/null || true
        echo ">>> Restored input engine: $PREV_ENGINE"
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
