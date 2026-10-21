#!/bin/bash
set -euo pipefail

# Remove what install.sh added.
#
#     sudo bash apps/linux/scripts/uninstall.sh

if [[ $EUID -ne 0 ]]; then
    echo "error: this needs root — run: sudo bash $0" >&2
    exit 1
fi

FILES=(
    "/usr/libexec/byakaron-ibus"
    "/usr/bin/byakaron"
    "/usr/share/ibus/component/byakaron.xml"
    "/usr/share/applications/byakaron.desktop"
    "/usr/share/applications/dev.nuhu.labs.Byakaron.desktop"
    "/usr/share/metainfo/dev.nuhu.labs.Byakaron.metainfo.xml"
    "/usr/share/icons/hicolor/scalable/apps/byakaron.svg"
    "/usr/share/byakaron/spell.db"
    "/usr/share/glib-2.0/schemas/dev.nuhu.labs.Byakaron.gschema.xml"
    "/usr/share/fcitx5/addon/byakaron.conf"
    "/usr/share/fcitx5/inputmethod/byakaron.conf"
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
# The app holds no session state, but leaving it running against a deleted
# binary and a deleted spell.db is not worth the confusion.
pkill -x byakaron 2>/dev/null || true

for f in "${FILES[@]}"; do
    if [[ -e "$f" ]]; then
        rm -f "$f"
        echo ">>> Removed: $f"
    fi
done
# Multiarch addon path varies; remove whichever copy install.sh left.
rm -f /usr/lib/fcitx5/byakaron.so \
      /usr/lib/*/fcitx5/byakaron.so 2>/dev/null || true
rmdir /usr/share/byakaron 2>/dev/null || true
glib-compile-schemas /usr/share/glib-2.0/schemas >/dev/null 2>&1 || true
update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
gtk-update-icon-cache -qtf /usr/share/icons/hicolor >/dev/null 2>&1 || true

if pgrep -x ibus-daemon >/dev/null; then
    echo ">>> Refreshing the ibus registry..."
    as_user ibus write-cache >/dev/null 2>&1 || true
    as_user ibus restart >/dev/null 2>&1 || true
    sleep 2
fi

echo "=== Uninstalled ==="
