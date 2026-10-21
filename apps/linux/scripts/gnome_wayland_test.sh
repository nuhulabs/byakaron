#!/bin/bash
set -uo pipefail

# ---------------------------------------------------------------------------
# Type into GTK3 and GTK4 apps on a real GNOME Shell Wayland session, without
# logging out of the desktop:
#
#     bash apps/linux/scripts/gnome_wayland_test.sh
#
# Starts a *private* `gnome-shell --headless --wayland` with its own D-Bus,
# dconf, runtime dir and ibus-daemon (input source set to Byakaron), registers
# the build-tree engine, and opens a GTK window natively on that Wayland
# display. Keys and a click go in through org.gnome.Mutter.RemoteDesktop, so
# they take the same path as a real keyboard on an "Ubuntu on Wayland" login:
# text-input-v3 -> GNOME Shell -> IBus -> byakaron-ibus. Nothing touches the
# running desktop; everything it starts is stopped by runtime dir afterwards.
#
# Needs gnome-shell (46 tested), python3-gi with GTK 3 and 4, and a build:
# zig build linux. Exits non-zero if any check fails.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd)"

command -v gnome-shell >/dev/null || { echo "skip: gnome-shell not installed"; exit 0; }

ENGINE="${ENGINE:-$REPO_ROOT/zig-out/bin/byakaron-ibus}"
[[ -x "$ENGINE" ]] || { echo "error: $ENGINE missing (zig build linux)" >&2; exit 1; }

# Short paths: Unix socket names (at-spi, gvfs) must fit in 108 bytes.
W="$PROJECT_ROOT/build/gnome-wayland"
RUN="$W/run"
rm -rf "$W"; mkdir -p "$RUN" "$W/config" "$W/data" "$W/cache"; chmod 700 "$RUN"

XML="$W/byakaron.xml"
sed -e "s|@BYK_EXEC@|$ENGINE|g" -e "s|@BYK_ICON@|input-keyboard|g" -e "s|@BYK_SETUP@||g" \
    "$PROJECT_ROOT/Resources/byakaron.xml.in" > "$XML"

# The spelling-correction case needs a spell.db the engine can open.
BYK_SPELL_DB_PRESENT=0
[[ -f "${BYAKARON_SPELL_DB:-}" || -f /usr/share/byakaron/spell.db ]] && BYK_SPELL_DB_PRESENT=1
# The build tree's compiled schema, so gsettings and the engine agree on keys
# (the sandbox has its own dconf, the desktop's settings are not touched).
export GSETTINGS_SCHEMA_DIR="$REPO_ROOT/zig-out/share/glib-2.0/schemas"
export BYK_SETTINGS_TEST=1
export W RUN ENGINE XML PROJECT_ROOT BYK_SPELL_DB_PRESENT
export XDG_RUNTIME_DIR="$RUN" XDG_CONFIG_HOME="$W/config" XDG_DATA_HOME="$W/data" XDG_CACHE_HOME="$W/cache"
# Whatever forces a backend or IM module in the caller's session must not leak in.
unset DISPLAY WAYLAND_DISPLAY GTK_IM_MODULE QT_IM_MODULE XMODIFIERS SESSION_MANAGER \
      IBUS_ADDRESS GDK_BACKEND QT_QPA_PLATFORM CLUTTER_BACKEND

dbus-run-session -- bash -c '
set -u
sandboxed() { for p in $(pgrep -x "$1"); do grep -qsa "XDG_RUNTIME_DIR=$RUN" /proc/$p/environ && echo $p; done; }

gsettings set org.gnome.desktop.input-sources sources "[(\"ibus\", \"byakaron\")]"

# Our daemon on a fixed address. With --no-x11 the shell sees it and does not
# spawn its own (with X11 it starts a second, --replace one for XIM).
export IBUS_ADDRESS="unix:path=$RUN/ibus.sock"
ibus-daemon --address="$IBUS_ADDRESS" --panel disable --cache none >"$W/ibus.log" 2>&1 &
for _ in $(seq 1 60); do ibus list-engine >/dev/null 2>&1 && break; sleep 0.25; done
"$ENGINE" --xml "$XML" >"$W/engine.log" 2>&1 &
sleep 2

gnome-shell --headless --wayland --no-x11 --virtual-monitor 1280x800 \
    --wayland-display byk-wl >"$W/shell.log" 2>&1 &
shell=$!
for _ in $(seq 1 120); do [[ -S "$RUN/byk-wl" ]] && break; sleep 0.25; done
export WAYLAND_DISPLAY=byk-wl
sleep 5
ibus engine byakaron
echo ">>> gnome-shell $(gnome-shell --version | cut -d" " -f3) headless Wayland, ibus engine: $(ibus engine 2>&1)"
[[ -n "$(sandboxed byakaron-ibus)" ]] || { echo "error: build-tree engine not running"; tail -3 "$W/engine.log"; exit 1; }

fails=0
for ver in 3 4; do
    out="$W/text$ver.txt"; : >"$out"
    python3 "$PROJECT_ROOT/tests/wayland_textapp.py" $ver "$out" >"$W/app$ver.log" 2>&1 &
    app=$!
    for _ in $(seq 1 60); do grep -q "^\[app\]" "$W/app$ver.log" && break; sleep 0.5; done
    sleep 1
    grep "^\[app\]" "$W/app$ver.log" || { echo "error: GTK$ver app did not start"; tail -3 "$W/app$ver.log"; fails=$((fails+1)); continue; }
    python3 "$PROJECT_ROOT/tests/wayland_rdtest.py" "GTK$ver/Wayland" cat "$out" || fails=$((fails+1))
    kill $app; sleep 1
done
kill $shell 2>/dev/null; sleep 1
exit $fails
'
status=$?
for p in $(pgrep -u "$(id -u)"); do
    grep -qsa "XDG_RUNTIME_DIR=$RUN" /proc/$p/environ 2>/dev/null && kill "$p" 2>/dev/null
done
echo
[[ $status == 0 ]] && echo "gnome wayland test passed" || echo "GNOME WAYLAND TEST FAILED"
exit $status
