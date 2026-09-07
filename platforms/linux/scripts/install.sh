#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Install the Byakaron IBus engine so it survives a reboot and appears in
# GNOME Settings -> Keyboard -> Input Sources.
#
#     sudo bash platforms/linux/scripts/install.sh
#
# This is a system install because it has to be: ibus-daemon builds its registry
# by scanning /usr/share/ibus/component only. A copy under
# ~/.local/share/ibus/component is never read, and IBUS_COMPONENT_PATH is not
# honoured by ibus 1.5.x (both were verified on 1.5.29). Every other engine on
# the system -- ibus-avro included -- installs the same way.
#
# For day-to-day development use scripts/dev_run.sh instead, which registers
# with the running daemon straight from the build tree and needs no root.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd)"

LIBDIR="/usr/libexec"
BINDIR="/usr/bin"
XMLDIR="/usr/share/ibus/component"
ICONDIR="/usr/share/icons/hicolor/scalable/apps"
DESKTOPDIR="/usr/share/applications"
DATADIR="/usr/share/byakaron"

if [[ $EUID -ne 0 ]]; then
    echo "error: this needs root — run: sudo bash $0" >&2
    exit 1
fi

# Build as the invoking user: zig lives in their ~/.local and writes a cache
# into the repo, and doing that as root would leave root-owned artifacts behind.
BUILD_USER="${SUDO_USER:-root}"

as_build_user() {
    if [[ "$BUILD_USER" != "root" ]]; then
        sudo -u "$BUILD_USER" -H bash -lc \
            "cd '$REPO_ROOT' && PATH=\"\$HOME/.local/bin:/usr/local/bin:\$PATH\" $1"
    else
        ( cd "$REPO_ROOT" && eval "$1" )
    fi
}

echo ">>> Building byakaron-ibus..."
as_build_user "zig build linux -Doptimize=ReleaseFast"

SRC_BIN="$REPO_ROOT/zig-out/bin/byakaron-ibus"
[[ -x "$SRC_BIN" ]] || { echo "error: $SRC_BIN missing" >&2; exit 1; }

# The GTK app is optional: the input method is the product, and this keeps a
# box with only libibus-dev able to install a working keyboard.
SRC_APP="$REPO_ROOT/zig-out/bin/byakaron"
if pkg-config --exists gtk4 libadwaita-1 2>/dev/null; then
    echo ">>> Building the GTK app..."
    as_build_user "zig build linux-app -Doptimize=ReleaseFast" || true
else
    echo "note: gtk4 / libadwaita-1 not found — skipping the GTK app"
    echo "      install them with: sudo bash platforms/linux/scripts/setup_deps.sh"
fi

install -d "$LIBDIR" "$BINDIR" "$XMLDIR" "$ICONDIR" "$DESKTOPDIR" "$DATADIR"

# Install the binary before the XML: the XML points at its final path and ibus
# will try to exec exactly that.
install -m 755 "$SRC_BIN" "$LIBDIR/byakaron-ibus"
echo ">>> Installed: $LIBDIR/byakaron-ibus"

install -m 644 "$PROJECT_ROOT/Resources/byakaron.svg" "$ICONDIR/byakaron.svg"
echo ">>> Installed: $ICONDIR/byakaron.svg"

# The app goes in /usr/bin, not /usr/libexec: it is something the user launches,
# unlike the engine, which only ibus-daemon ever execs.
BYK_SETUP=""
if [[ -x "$SRC_APP" ]]; then
    install -m 755 "$SRC_APP" "$BINDIR/byakaron"
    echo ">>> Installed: $BINDIR/byakaron"

    sed -e "s|@BYK_APP_EXEC@|$BINDIR/byakaron|g" \
        "$PROJECT_ROOT/Resources/byakaron-app.desktop.in" > "$DESKTOPDIR/byakaron.desktop"
    chmod 644 "$DESKTOPDIR/byakaron.desktop"
    echo ">>> Installed: $DESKTOPDIR/byakaron.desktop"

    BYK_SETUP="$BINDIR/byakaron"
fi

SPELL_DB="$REPO_ROOT/packages/data/spell.db"
if [[ -f "$SPELL_DB" ]]; then
    install -m 644 "$SPELL_DB" "$DATADIR/spell.db"
    echo ">>> Installed: $DATADIR/spell.db"
else
    echo "note: $SPELL_DB missing — spell-check will be unavailable"
    echo "      build it with: bash platforms/linux/scripts/prepare_spell_db.sh"
fi

sed -e "s|@BYK_EXEC@|$LIBDIR/byakaron-ibus|g" \
    -e "s|@BYK_ICON@|$ICONDIR/byakaron.svg|g" \
    -e "s|@BYK_SETUP@|$BYK_SETUP|g" \
    "$PROJECT_ROOT/Resources/byakaron.xml.in" > "$XMLDIR/byakaron.xml"
chmod 644 "$XMLDIR/byakaron.xml"
echo ">>> Installed: $XMLDIR/byakaron.xml"

# Without these the app has no icon and does not show up in the activities
# search until the desktop rescans on its own schedule.
if [[ -n "$BYK_SETUP" ]]; then
    update-desktop-database "$DESKTOPDIR" >/dev/null 2>&1 || true
fi
gtk-update-icon-cache -qtf /usr/share/icons/hicolor >/dev/null 2>&1 || true

# ibus caches the registry, so a new component stays invisible until the daemon
# re-reads it. Restarting drops the active engine, so put it back afterwards.
# Both must run as the desktop user: the daemon and cache belong to their
# session, not to root.
as_user() {
    if [[ "$BUILD_USER" != "root" ]]; then
        sudo -u "$BUILD_USER" -H \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$BUILD_USER")/bus" \
            "$@"
    else
        "$@"
    fi
}

if pgrep -x ibus-daemon >/dev/null; then
    PREV_ENGINE="$(as_user ibus engine 2>/dev/null || true)"
    case "$PREV_ENGINE" in *"No engine"* | "") PREV_ENGINE="" ;; esac

    echo ">>> Refreshing the ibus registry..."
    as_user ibus write-cache >/dev/null 2>&1 || true
    as_user ibus restart >/dev/null 2>&1 || true
    sleep 2

    if [[ -n "$PREV_ENGINE" ]]; then
        as_user ibus engine "$PREV_ENGINE" >/dev/null 2>&1 || true
        echo ">>> Restored input engine: $PREV_ENGINE"
    fi
else
    echo "note: ibus-daemon is not running; the engine appears once it starts"
fi

echo
if as_user ibus list-engine 2>/dev/null | grep -q '\bbyakaron\b'; then
    echo "=== Installed. 'byakaron' is in the ibus registry. ==="
else
    echo "!!! Installed, but 'byakaron' is not listed by 'ibus list-engine' yet." >&2
    echo "    Log out and back in, then run 'ibus list-engine | grep byakaron'." >&2
fi
echo
echo "To start typing Bangla:"
echo "  1. Settings -> Keyboard -> Input Sources -> '+'"
echo "  2. Search 'Byakaron' (filed under Bangla), then Add"
echo "  3. Switch with Super+Space"
if [[ -n "$BYK_SETUP" ]]; then
    echo
    echo "The 'Byakaron' app is installed too — it walks through the steps above,"
    echo "types Bangla without switching input source, and checks spelling."
fi
