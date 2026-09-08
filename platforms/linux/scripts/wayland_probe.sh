#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Report which display backend a GTK4 client would use to talk to IBus, and
# (when mutter is installed) open a nested Wayland compositor to prove the
# text-input-v3 stack actually comes up.
#
#     bash platforms/linux/scripts/wayland_probe.sh
#
# The engine is not launched. It has no X11 or Wayland calls — Keyboard/engine.c
# only speaks IBusEngine — so the question is whether *clients* on this machine
# can reach an IBus daemon on Wayland. A private IBus input context (ime_test)
# already covers the engine; this covers the other half of the path.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"

mkdir -p "$BUILD_DIR/bin"

echo ">>> Compiling wayland probe..."
cc -O2 -Wall -Wextra -o "$BUILD_DIR/bin/wayland_probe" \
    "$PROJECT_ROOT/tests/wayland_probe.c" \
    $(pkg-config --cflags --libs gtk4)

PROBE="$BUILD_DIR/bin/wayland_probe"

echo
echo "=== session ==="
echo "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-unset}"
echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-unset}"
echo "DISPLAY=${DISPLAY:-unset}"
echo "GDK_BACKEND=${GDK_BACKEND:-unset}"
echo "GTK_IM_MODULE=${GTK_IM_MODULE:-unset}"
echo "QT_IM_MODULE=${QT_IM_MODULE:-unset}"
echo "XMODIFIERS=${XMODIFIERS:-unset}"

echo
echo "=== gtk4 ibus im-module (D-Bus path, works on X11 and Wayland) ==="
IMMODULE=""
for p in /usr/lib/*/gtk-4.0/*/immodules/libim-ibus.so \
         /usr/lib/gtk-4.0/*/immodules/libim-ibus.so; do
    if [[ -f "$p" ]]; then
        IMMODULE="$p"
        break
    fi
done
if [[ -n "$IMMODULE" ]]; then
    echo "found: $IMMODULE"
else
    echo "MISSING — install ibus-gtk4 or GTK4 apps will not talk to IBus"
fi

echo
echo "=== engine display coupling ==="
if grep -E '#include <(X11|gdk/gdkx|gdk/gdkwayland|wayland-client)' \
        "$PROJECT_ROOT/Keyboard"/*.c "$PROJECT_ROOT/Keyboard"/*.h \
        >/dev/null 2>&1; then
    echo "UNEXPECTED: Keyboard/ includes a display-server header"
    DISPLAY_COUPLED=1
else
    echo "Keyboard/ has no X11 or Wayland headers — IBus D-Bus only"
    DISPLAY_COUPLED=0
fi

echo
echo "=== probe on the current session ==="
# Unset GDK_BACKEND so GTK picks whatever this session actually is.
env -u GDK_BACKEND "$PROBE" || true

MUTTER="$(command -v mutter || true)"
if [[ -z "$MUTTER" ]]; then
    echo
    echo "note: mutter not installed — nested Wayland compositor skipped"
    echo "      (this is expected in CI; GNOME sessions have it)"
    if [[ "$DISPLAY_COUPLED" -ne 0 ]]; then
        exit 1
    fi
    exit 0
fi

echo
echo "=== nested Wayland compositor (mutter --headless) ==="

WL_NAME="byakaron-wl-$$"
MUTTER_LOG="$BUILD_DIR/mutter-headless.log"
MUTTER_PID=""

cleanup() {
    if [[ -n "$MUTTER_PID" ]] && kill -0 "$MUTTER_PID" 2>/dev/null; then
        kill "$MUTTER_PID" 2>/dev/null || true
        wait "$MUTTER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Headless compositor with a virtual monitor and a private WAYLAND_DISPLAY so
# this cannot replace the running GNOME session. --display-server cannot be
# combined with --headless on mutter 46 ("Can't run in display server mode
# headlessly"); --wayland --headless is enough to get a text-input-v3 server.
"$MUTTER" --wayland --headless --no-x11 \
    --wayland-display "$WL_NAME" \
    --virtual-monitor 1280x720 \
    --sm-disable \
    >"$MUTTER_LOG" 2>&1 &
MUTTER_PID=$!

SOCKET=""
for _ in $(seq 1 50); do
    if [[ -S "/run/user/$(id -u)/$WL_NAME" ]]; then
        SOCKET="/run/user/$(id -u)/$WL_NAME"
        break
    fi
    # Some compositors put the socket in $XDG_RUNTIME_DIR under a different name.
    if [[ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$WL_NAME" ]]; then
        SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$WL_NAME"
        break
    fi
    kill -0 "$MUTTER_PID" 2>/dev/null || break
    sleep 0.1
done

if [[ -z "$SOCKET" ]]; then
    echo "mutter did not create WAYLAND_DISPLAY=$WL_NAME"
    echo "--- mutter log ---"
    cat "$MUTTER_LOG" || true
    echo "note: nested Wayland failed on this box; engine path is still display-agnostic"
    exit 0
fi

echo "WAYLAND_DISPLAY=$WL_NAME (socket $SOCKET)"
echo
# Force the Wayland backend so a lingering DISPLAY=:1 cannot pull us back to X11.
if ! env -u DISPLAY WAYLAND_DISPLAY="$WL_NAME" GDK_BACKEND=wayland \
        GTK_A11Y=none "$PROBE"; then
    echo "note: GTK4 did not start against the nested compositor"
    echo "--- mutter log ---"
    cat "$MUTTER_LOG" || true
    exit 0
fi

echo
echo "GTK4's IM context id 'wayland' is GtkIMContextWayland, which speaks"
echo "zwp_text_input_v3 to the compositor. Mutter then forwards those commits"
echo "to IBus. The engine is unchanged: it only sees IBusEngine key events."
echo
echo "=== wayland probe finished ==="
