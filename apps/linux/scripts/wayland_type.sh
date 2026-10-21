#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Type Bangla into a GtkEntry through GTK_IM_MODULE=ibus.
#
#     bash apps/linux/scripts/wayland_type.sh
#
# Starts a throwaway byakaron-ibus (same as test_ime.sh), then either:
#   - a nested mutter compositor, forcing GDK_BACKEND=wayland, or
#   - the current DISPLAY (X11 / Xvfb) if mutter is missing.
#
# This is not "Firefox on a Wayland login". Standalone mutter has no
# gnome-shell IM bridge, so text-input-v3 would not reach IBus. Forcing the
# IBus GTK module from a Wayland client is the path we can actually drive.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
ZIG="${ZIG_EXE:-$(command -v zig || true)}"
[[ -n "$ZIG" ]] || { echo "error: no 'zig' on PATH" >&2; exit 1; }

if ! pgrep -x ibus-daemon >/dev/null; then
    echo "error: ibus-daemon is not running" >&2
    exit 1
fi

if [[ -z "${BYAKARON_SPELL_DB:-}" && -f "$REPO_ROOT/zig-out/db/spell.db" ]]; then
    export BYAKARON_SPELL_DB="$REPO_ROOT/zig-out/db/spell.db"
fi

echo ">>> Building engine..."
( cd "$REPO_ROOT" && "$ZIG" build linux -Doptimize="${ZIG_OPTIMIZE:-ReleaseFast}" )

mkdir -p "$BUILD_DIR/bin"
echo ">>> Compiling wayland type test..."
cc -O2 -Wall -Wextra -o "$BUILD_DIR/bin/wayland_type" \
    "$PROJECT_ROOT/tests/wayland_type.c" \
    $(pkg-config --cflags --libs gtk4)

BIN="$REPO_ROOT/zig-out/bin/byakaron-ibus"
XML="$PROJECT_ROOT/build/byakaron.xml"
PROBE="$BUILD_DIR/bin/wayland_type"

mkdir -p "$PROJECT_ROOT/build"
sed -e "s|@BYK_EXEC@|$BIN|g" \
    -e "s|@BYK_ICON@|input-keyboard|g" \
    -e "s|@BYK_SETUP@||g" \
    "$PROJECT_ROOT/Resources/byakaron.xml.in" > "$XML"

PREV_ENGINE="$(ibus engine 2>/dev/null || true)"
case "$PREV_ENGINE" in
    *"No engine"* | "") PREV_ENGINE="" ;;
esac

ENGINE_PID=""
MUTTER_PID=""
MUTTER_LOG="$BUILD_DIR/mutter-type.log"

cleanup() {
    if [[ -n "$MUTTER_PID" ]] && kill -0 "$MUTTER_PID" 2>/dev/null; then
        kill "$MUTTER_PID" 2>/dev/null || true
        wait "$MUTTER_PID" 2>/dev/null || true
    fi
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
for _ in $(seq 1 30); do
    kill -0 "$ENGINE_PID" 2>/dev/null || { echo "error: engine exited early" >&2; exit 1; }
    sleep 0.2
done

# GtkIMContext talks to the session's current engine, not a private IC.
ibus engine byakaron >/dev/null
echo ">>> ibus engine byakaron"

run_probe() {
    env GTK_IM_MODULE=ibus GTK_A11Y=none "$PROBE"
}

MUTTER="$(command -v mutter || true)"
if [[ -n "$MUTTER" ]]; then
    echo
    echo "=== nested Wayland compositor (mutter --headless) ==="
    WL_NAME="byakaron-type-$$"
    "$MUTTER" --wayland --headless --no-x11 \
        --wayland-display "$WL_NAME" \
        --virtual-monitor 1280x720 \
        --sm-disable \
        >"$MUTTER_LOG" 2>&1 &
    MUTTER_PID=$!

    SOCKET=""
    for _ in $(seq 1 50); do
        if [[ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$WL_NAME" ]]; then
            SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$WL_NAME"
            break
        fi
        kill -0 "$MUTTER_PID" 2>/dev/null || break
        sleep 0.1
    done

    if [[ -n "$SOCKET" ]]; then
        echo "WAYLAND_DISPLAY=$WL_NAME"
        echo
        # timeout: GTK4 + IBus + a nested compositor can block in
        # gtk_application_run. 25s is well above a passing X11 run (~5s).
        if timeout 25 env -u DISPLAY WAYLAND_DISPLAY="$WL_NAME" \
                GDK_BACKEND=wayland GTK_IM_MODULE=ibus GTK_A11Y=none "$PROBE"; then
            echo
            echo "=== wayland type test finished (nested mutter) ==="
            exit 0
        fi
        echo "note: nested Wayland typing failed or timed out; falling back to the session display"
        echo "--- mutter log ---"
        cat "$MUTTER_LOG" || true
        kill "$MUTTER_PID" 2>/dev/null || true
        wait "$MUTTER_PID" 2>/dev/null || true
        MUTTER_PID=""
    else
        echo "note: mutter did not publish WAYLAND_DISPLAY=$WL_NAME"
        echo "--- mutter log ---"
        cat "$MUTTER_LOG" || true
        MUTTER_PID=""
    fi
else
    echo
    echo "note: mutter not installed — typing against the current display instead"
fi

if [[ -z "${DISPLAY:-}" ]]; then
    echo "error: no DISPLAY and nested Wayland failed" >&2
    exit 1
fi

echo
echo "=== GtkEntry typing on DISPLAY=$DISPLAY ==="
run_probe
echo
echo "=== wayland type test finished (session display) ==="
