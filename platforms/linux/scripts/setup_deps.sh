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

# ibus + glib: the input-method engine. gtk4 + libadwaita: the settings app.
# ibus-gtk4 is the client-side im-module, without which GTK4 apps never talk to
# the engine at all.
PACKAGES=(
    build-essential
    pkg-config
    libibus-1.0-dev
    libglib2.0-dev
    libgtk-4-dev
    libadwaita-1-dev
    gettext
    ibus
    ibus-gtk4
)

echo ">>> apt-get update"
apt-get update -qq

echo ">>> installing: ${PACKAGES[*]}"
apt-get install -y "${PACKAGES[@]}"

echo
echo ">>> verifying pkg-config modules"
STATUS=0
for m in ibus-1.0 glib-2.0 gtk4 libadwaita-1; do
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
