#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Check an *installed* Byakaron (.deb, install.sh, or the curl installer):
# files in place, no missing libraries, and the IME test typing through the
# installed engine — not a build-tree one.
#
#     sudo apt install ./byakaron_<ver>_<arch>.deb
#     bash platforms/linux/scripts/test_installed.sh [path/to/byakaron-ime-test] [expected-version]
#
# Starts its own Xvfb + dbus + ibus-daemon, so it runs on a CI runner or in a
# container with no desktop. `ibus engine byakaron` makes the daemon launch the
# <exec> from /usr/share/ibus/component/byakaron.xml, which is what a user gets.
# Needs: xvfb, dbus-x11, ibus.
# ---------------------------------------------------------------------------

# Containers default to the C locale, which prints every Bangla letter as "?".
export LC_ALL="${LC_ALL:-C.UTF-8}"

IME_TEST="${1:-zig-out/bin/byakaron-ime-test}"
WANT_VERSION="${2:-}"
COMPONENT=/usr/share/ibus/component/byakaron.xml
failures=0

ok()   { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; failures=$((failures + 1)); }

echo "=== installed files ==="
for f in "$COMPONENT" \
         /usr/share/icons/hicolor/scalable/apps/byakaron.svg \
         /usr/share/applications/dev.nuhu.labs.Byakaron.desktop \
         /usr/share/glib-2.0/schemas/dev.nuhu.labs.Byakaron.gschema.xml; do
    [[ -e "$f" ]] && ok "$f" || fail "missing $f"
done
# The app grid draws this with gdk-pixbuf; 0.1.8's icon failed to load there.
icon=/usr/share/icons/hicolor/scalable/apps/byakaron.svg
if python3 -c "import gi; gi.require_version('GdkPixbuf', '2.0')" 2>/dev/null; then
    if python3 -c "
import sys, gi; gi.require_version('GdkPixbuf', '2.0')
from gi.repository import GdkPixbuf
GdkPixbuf.Pixbuf.new_from_file_at_size(sys.argv[1], 64, 64)" "$icon" 2>/dev/null; then
        ok "icon loads in gdk-pixbuf"
    else
        fail "icon does not load in gdk-pixbuf (blank in the app grid)"
    fi
else
    echo "  note python3-gi not installed, icon load not checked"
fi
[[ -e /usr/share/byakaron/spell.db ]] && ok "spell.db" || echo "  note spell.db not installed (spell-check off, typing unaffected)"

ENGINE="$(sed -n 's|.*<exec>\([^ <]*\).*|\1|p' "$COMPONENT" 2>/dev/null || true)"
APP="$(command -v byakaron || true)"
[[ -x "$ENGINE" ]] && ok "engine $ENGINE" || fail "engine not executable: '$ENGINE'"
[[ -n "$APP" ]] && ok "app $APP" || fail "app 'byakaron' not on PATH"

missing="$(ldd "$ENGINE" ${APP:+"$APP"} 2>&1 | grep -c 'not found' || true)"
[[ "$missing" == 0 ]] && ok "no missing libraries" || fail "$missing missing libraries"

if [[ -n "$APP" ]]; then
    got="$("$APP" --version 2>/dev/null || true)"
    if [[ -z "$WANT_VERSION" || "$got" == "byakaron $WANT_VERSION" ]]; then
        ok "app version: $got"
    else
        fail "app version: '$got', expected 'byakaron $WANT_VERSION'"
    fi
fi

echo
echo "=== IME test through the installed engine ==="
if [[ ! -x "$IME_TEST" ]]; then
    fail "IME test binary not found: $IME_TEST (zig build linux-test)"
else
    display=97
    while [[ -e "/tmp/.X${display}-lock" ]]; do display=$((display + 1)); done
    export DISPLAY=":${display}"
    Xvfb "$DISPLAY" -screen 0 1024x768x24 -nolisten tcp >/dev/null 2>&1 &
    xvfb=$!
    trap 'kill $xvfb 2>/dev/null || true' EXIT
    sleep 0.5

    # Wait on list-engine, not `ibus address`: the address file can be left
    # over from an earlier daemon on the same display and answer instantly.
    log="$(mktemp)"
    set +e
    dbus-run-session -- bash -c '
        ibus-daemon --single --xim --panel disable --config disable --cache none >/dev/null 2>&1 &
        for _ in $(seq 1 60); do ibus list-engine >/dev/null 2>&1 && break; sleep 0.25; done
        ibus list-engine 2>/dev/null | grep -q "byakaron" || { echo "  FAIL byakaron not in ibus list-engine"; exit 1; }
        echo "  ok   registered with ibus-daemon"
        "$0"
    ' "$IME_TEST" >"$log" 2>&1
    status=$?
    set -e
    grep -E '^  (ok|FAIL|skip)|^       expected|^ime test|^ime_test' "$log" || true
    rm -f "$log"
    # 77 is the test's "engine unreachable" skip: for an install that is a failure.
    [[ "$status" == 0 ]] || fail "IME test exited $status"
fi

echo
if [[ "$failures" -gt 0 ]]; then
    echo "INSTALLED CHECK FAILED ($failures)"
    exit 1
fi
echo "installed check passed"
