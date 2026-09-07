#!/bin/bash
set -euo pipefail

# Remove what install.sh added.
#
#     sudo bash platforms/linux/scripts/uninstall.sh

if [[ $EUID -ne 0 ]]; then
    echo "error: this needs root — run: sudo bash $0" >&2
    exit 1
fi

FILES=(
    "/usr/libexec/byakaron-ibus"
    "/usr/share/ibus/component/byakaron.xml"
    "/usr/share/icons/hicolor/scalable/apps/byakaron.svg"
    "/usr/share/byakaron/spell.db"
)

DESKTOP_USER="${SUDO_USER:-root}"
as_user() {
    if [[ "$DESKTOP_USER" != "root" ]]; then
        sudo -u "$DESKTOP_USER" -H \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$DESKTOP_USER")/bus" \
            "$@"
    else
        "$@"
    fi
}

# Switch away first: pulling the binary out from under the active engine would
# leave the session unable to type.
if pgrep -x ibus-daemon >/dev/null && \
   [[ "$(as_user ibus engine 2>/dev/null || true)" == "byakaron" ]]; then
    echo ">>> byakaron is active; switching to xkb:us::eng first"
    as_user ibus engine xkb:us::eng >/dev/null 2>&1 || true
fi

pkill -f '[b]yakaron-ibus' 2>/dev/null || true

for f in "${FILES[@]}"; do
    if [[ -e "$f" ]]; then
        rm -f "$f"
        echo ">>> Removed: $f"
    fi
done
rmdir /usr/share/byakaron 2>/dev/null || true

if pgrep -x ibus-daemon >/dev/null; then
    echo ">>> Refreshing the ibus registry..."
    as_user ibus write-cache >/dev/null 2>&1 || true
    as_user ibus restart >/dev/null 2>&1 || true
    sleep 2
fi

echo "=== Uninstalled ==="
