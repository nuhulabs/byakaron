#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Install the system development packages the Linux port needs.
#
#   sudo bash platforms/linux/scripts/setup_deps.sh
#
# Zig itself is NOT installed here: this branch is pinned to a specific 0.17-dev
# build that the distro does not ship. See platforms/linux/README.md.
# ---------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "error: run me with sudo — 'sudo bash $0'" >&2
    exit 1
fi

# ibus + glib: the input-method engine. gtk3: the settings app (20.04 / 22.04 /
# 24.04). ibus-gtk3 is the client-side im-module GTK3 apps use to talk to IBus.
# gtk4 / ibus-gtk4 are optional: CI typing tests on 24.04, not the shipped app.
PACKAGES=(
    build-essential
    pkg-config
    libibus-1.0-dev
    libglib2.0-dev
    libgtk-3-dev
    gettext
    ibus
    ibus-gtk3
)

echo ">>> apt-get update"
apt-get update -qq

echo ">>> installing: ${PACKAGES[*]}"
apt-get install -y "${PACKAGES[@]}"

# GTK4 is only needed for the IME typing tests (wayland_type.c), not the app.
if apt-cache show libgtk-4-dev >/dev/null 2>&1; then
    echo ">>> installing optional GTK4 (IME tests): libgtk-4-dev ibus-gtk4"
    apt-get install -y libgtk-4-dev ibus-gtk4 || true
fi

echo
echo ">>> verifying pkg-config modules"
STATUS=0
for m in ibus-1.0 glib-2.0 gtk+-3.0; do
    if v=$(pkg-config --modversion "$m" 2>/dev/null); then
        printf '    %-14s %s\n' "$m" "$v"
    else
        printf '    %-14s MISSING\n' "$m"
        STATUS=1
    fi
done

echo
if [[ $STATUS -eq 0 ]]; then
    echo "=== dependencies ready ==="
else
    echo "!!! some modules are still missing — see above" >&2
fi
exit $STATUS
