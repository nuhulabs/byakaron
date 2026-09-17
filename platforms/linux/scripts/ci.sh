#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# What GitHub Actions runs on ubuntu-latest, and what you can run here to see
# the same failures before pushing.
#
#     bash platforms/linux/scripts/ci.sh
#
# Builds the shared library, the IBus engine, the GTK app, the IME test, then
# runs smoke.sh. The IME integration test needs an ibus-daemon: in CI (no
# session) this script starts Xvfb + dbus + ibus itself; on a desktop it uses
# the one already running.
#
# Does NOT generate spell.db (364 MB) and does not need it — smoke skips those
# assertions when the file is absent.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd)"

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
ZIG="${ZIG_EXE:-$(command -v zig || true)}"
[[ -n "$ZIG" ]] || { echo "error: no zig on PATH" >&2; exit 1; }

echo ">>> zig $($ZIG version)"
echo ">>> cwd $REPO_ROOT"

cd "$REPO_ROOT"

echo
echo "=== zig build linux + linux-test (glibc 2.31) + linux-app + -Dshared ==="
# shellcheck source=compat.sh
source "$SCRIPT_DIR/compat.sh"
COMPAT_TARGET="$(byk_compat_target_flag)"
"$ZIG" build linux linux-test -Dshared=true -Doptimize=ReleaseFast $COMPAT_TARGET
"$ZIG" build linux-app -Doptimize=ReleaseFast $COMPAT_TARGET
byk_assert_glibc_20_04 "$REPO_ROOT/zig-out/bin/byakaron-ibus"
byk_assert_glibc_20_04 "$REPO_ROOT/zig-out/bin/byakaron"

echo
echo "=== GTK3 app --help / --version (no display needed) ==="
help_out="$("$REPO_ROOT/zig-out/bin/byakaron" --help 2>&1)"
printf '%s\n' "$help_out" | grep -q -- '--version' || {
    echo "error: byakaron --help does not mention --version" >&2
    printf '%s\n' "$help_out" >&2
    exit 1
}
printf '%s\n' "$help_out" | grep -q -- '--page' || {
    echo "error: byakaron --help does not mention --page" >&2
    printf '%s\n' "$help_out" >&2
    exit 1
}
ver_out="$("$REPO_ROOT/zig-out/bin/byakaron" --version)"
expected="byakaron $(sed -n 's/^#define BYK_APP_VERSION "\(.*\)"/\1/p' "$PROJECT_ROOT/App/app.h")"
printf '%s\n' "$ver_out" | grep -qx "$expected" || {
    echo "error: expected '$expected', got: $ver_out" >&2
    exit 1
}
echo ">>> $ver_out"

echo
echo "=== smoke (C ABI + Core glue) ==="
bash "$SCRIPT_DIR/smoke.sh"

OWNED_IBUS=""
OWNED_XVFB=""
OWNED_DBUS=""

cleanup_ci_session() {
    if [[ -n "$OWNED_IBUS" ]]; then
        kill "$OWNED_IBUS" 2>/dev/null || true
        wait "$OWNED_IBUS" 2>/dev/null || true
    fi
    if [[ -n "$OWNED_XVFB" ]]; then
        kill "$OWNED_XVFB" 2>/dev/null || true
        wait "$OWNED_XVFB" 2>/dev/null || true
    fi
    if [[ -n "$OWNED_DBUS" ]]; then
        kill "$OWNED_DBUS" 2>/dev/null || true
        wait "$OWNED_DBUS" 2>/dev/null || true
    fi
}

start_headless_ibus() {
    echo
    echo "=== starting headless ibus (Xvfb + dbus) ==="

    if ! command -v Xvfb >/dev/null || ! command -v ibus-daemon >/dev/null; then
        echo "error: Xvfb and ibus-daemon are required for the IME test in CI" >&2
        echo "       install: xvfb ibus dbus-x11" >&2
        exit 1
    fi

    trap cleanup_ci_session EXIT

    local display_num=99
    # GitHub runners may already have something on :99; pick a free slot.
    while [[ -e "/tmp/.X${display_num}-lock" ]]; do
        display_num=$((display_num + 1))
    done
    export DISPLAY=":${display_num}"

    Xvfb "$DISPLAY" -screen 0 1024x768x24 -nolisten tcp >/tmp/byakaron-xvfb.log 2>&1 &
    OWNED_XVFB=$!
    sleep 0.4
    kill -0 "$OWNED_XVFB" 2>/dev/null || {
        echo "error: Xvfb failed to start" >&2
        cat /tmp/byakaron-xvfb.log >&2 || true
        exit 1
    }

    local dbus_out
    dbus_out="$(dbus-launch --sh-syntax)"
    eval "$dbus_out"
    # dbus-launch prints DBUS_SESSION_BUS_PID.
    OWNED_DBUS="${DBUS_SESSION_BUS_PID:-}"

    ibus-daemon --single --xim \
        --panel disable --config disable --cache none &
    OWNED_IBUS=$!

    local i
    for i in $(seq 1 40); do
        if ibus address >/dev/null 2>&1; then
            echo ">>> ibus ready on DISPLAY=$DISPLAY"
            return 0
        fi
        sleep 0.15
    done
    echo "error: ibus-daemon started but never answered 'ibus address'" >&2
    exit 1
}

echo
if pgrep -x ibus-daemon >/dev/null; then
    echo "=== IME integration test (session ibus-daemon) ==="
    bash "$SCRIPT_DIR/test_ime.sh"
elif [[ "${CI:-}" == "true" || "${BYAKARON_CI:-}" == "1" ]]; then
    start_headless_ibus
    echo "=== IME integration test (headless ibus-daemon) ==="
    bash "$SCRIPT_DIR/test_ime.sh"
else
    echo "=== IME integration test skipped ==="
    echo "note: no ibus-daemon, and this is not CI. Start IBus or re-run with"
    echo "      BYAKARON_CI=1 to spawn a throwaway Xvfb+ibus (needs xvfb, ibus)."
fi

echo
echo "=== wayland / display-path probe ==="
# Best-effort: missing mutter (CI) is a skip, not a failure. A coupled engine
# (X11 headers in Keyboard/) would fail the script.
bash "$SCRIPT_DIR/wayland_probe.sh"

echo
if pkg-config --exists Fcitx5Core; then
    echo "=== Fcitx5 addon (glibc 2.31) ==="
    "$ZIG" build linux-fcitx5 -Doptimize=ReleaseFast $COMPAT_TARGET
    so="$REPO_ROOT/zig-out/lib/fcitx5/byakaron.so"
    if ! nm -D "$so" 2>/dev/null | grep -q 'fcitx_addon_factory_instance'; then
        echo "error: $so does not export fcitx_addon_factory_instance" >&2
        exit 1
    fi
    byk_assert_glibc_20_04 "$so"
    echo ">>> $so exports fcitx_addon_factory_instance"
else
    echo "=== Fcitx5 addon skipped (no Fcitx5Core.pc) ==="
fi

echo
echo "=== GtkEntry typing (IBus IM module) ==="
# Needs a running ibus-daemon, which the IME block above either found or started.
if pgrep -x ibus-daemon >/dev/null; then
    bash "$SCRIPT_DIR/wayland_type.sh"
else
    echo "note: no ibus-daemon — GtkEntry typing skipped"
fi

echo
echo "=== AppStream metainfo ==="
if ! command -v appstreamcli >/dev/null; then
    echo "error: appstreamcli is required (apt install appstream)" >&2
    exit 1
fi
appstreamcli validate --no-net \
    "$PROJECT_ROOT/Resources/dev.nuhu.labs.Byakaron.metainfo.xml"

echo
echo "=== ci.sh finished ==="
