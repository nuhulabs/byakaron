#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Install the Byakaron IBus engine so it survives a reboot and appears in
# GNOME Settings -> Keyboard -> Input Sources.
#
#     sudo bash apps/linux/scripts/install.sh
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

# shellcheck source=compat.sh
source "$SCRIPT_DIR/compat.sh"
COMPAT_TARGET="$(byk_compat_target_flag)"

LIBDIR="/usr/libexec"
BINDIR="/usr/bin"
XMLDIR="/usr/share/ibus/component"
ICONDIR="/usr/share/icons/hicolor/scalable/apps"
DESKTOPDIR="/usr/share/applications"
METAINFO_DIR="/usr/share/metainfo"
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

# Earlier `sudo zig` (or an unprivileged sandbox) can leave .zig-cache owned by
# root/nobody. The build below runs as $BUILD_USER, and Zig then dies with
# manifest_create AccessDenied. We still have root here, so give the cache back.
if [[ "$BUILD_USER" != "root" ]]; then
    USER_HOME="$(getent passwd "$BUILD_USER" | cut -d: -f6)"
    for d in "$REPO_ROOT/.zig-cache" "$REPO_ROOT/zig-out" "${USER_HOME:+$USER_HOME/.cache/zig}"; do
        [[ -e "$d" ]] || continue
        chown -R "$BUILD_USER:" "$d"
    done
fi

echo ">>> Building byakaron-ibus${COMPAT_TARGET:+ ($COMPAT_TARGET)}..."
as_build_user "zig build linux -Doptimize=ReleaseFast ${COMPAT_TARGET}"

SRC_BIN="$REPO_ROOT/zig-out/bin/byakaron-ibus"
[[ -x "$SRC_BIN" ]] || { echo "error: $SRC_BIN missing" >&2; exit 1; }
byk_assert_glibc_20_04 "$SRC_BIN"

# The GTK app is optional: the input method is the product, and this keeps a
# box with only libibus-dev able to install a working keyboard.
# Do not ship a leftover zig-out binary when this run did not rebuild it —
# that is how an older app keeps showing after install.sh.
SRC_APP="$REPO_ROOT/zig-out/bin/byakaron"
APP_BUILT=0
if pkg-config --exists gtk+-3.0 2>/dev/null; then
    echo ">>> Building the GTK3 app..."
    if as_build_user "zig build linux-app -Doptimize=ReleaseFast ${COMPAT_TARGET}"; then
        APP_BUILT=1
        byk_assert_glibc_20_04 "$SRC_APP"
    else
        echo "warning: linux-app build failed — leaving /usr/bin/byakaron unchanged" >&2
    fi
else
    echo "note: gtk+-3.0 not found — skipping the GTK app"
    echo "      install it with: sudo bash apps/linux/scripts/setup_deps.sh"
fi

SCHEMADIR="/usr/share/glib-2.0/schemas"

install -d "$LIBDIR" "$BINDIR" "$XMLDIR" "$ICONDIR" "$DESKTOPDIR" "$METAINFO_DIR" "$DATADIR" "$SCHEMADIR"

# Install the binary before the XML: the XML points at its final path and ibus
# will try to exec exactly that.
install -m 755 "$SRC_BIN" "$LIBDIR/byakaron-ibus"
echo ">>> Installed: $LIBDIR/byakaron-ibus"

install -m 644 "$PROJECT_ROOT/Resources/byakaron.svg" "$ICONDIR/byakaron.svg"
echo ">>> Installed: $ICONDIR/byakaron.svg"

install -m 644 "$PROJECT_ROOT/Resources/dev.nuhu.labs.Byakaron.gschema.xml" \
    "$SCHEMADIR/dev.nuhu.labs.Byakaron.gschema.xml"
glib-compile-schemas "$SCHEMADIR"
echo ">>> Installed: $SCHEMADIR/dev.nuhu.labs.Byakaron.gschema.xml"

# The app goes in /usr/bin, not /usr/libexec: it is something the user launches,
# unlike the engine, which only ibus-daemon ever execs.
BYK_SETUP=""
if [[ "$APP_BUILT" -eq 1 && -x "$SRC_APP" ]]; then
    install -m 755 "$SRC_APP" "$BINDIR/byakaron"
    echo ">>> Installed: $BINDIR/byakaron"

    sed -e "s|@BYK_APP_EXEC@|$BINDIR/byakaron|g" \
        "$PROJECT_ROOT/Resources/byakaron-app.desktop.in" > "$DESKTOPDIR/dev.nuhu.labs.Byakaron.desktop"
    chmod 644 "$DESKTOPDIR/dev.nuhu.labs.Byakaron.desktop"
    install -m 644 "$PROJECT_ROOT/Resources/dev.nuhu.labs.Byakaron.metainfo.xml" "$METAINFO_DIR/dev.nuhu.labs.Byakaron.metainfo.xml"
    echo ">>> Installed: $DESKTOPDIR/dev.nuhu.labs.Byakaron.desktop"
    echo ">>> Installed: $METAINFO_DIR/dev.nuhu.labs.Byakaron.metainfo.xml"

    BYK_SETUP="$BINDIR/byakaron --page=setup"
fi

SPELL_DB="$REPO_ROOT/packages/data/spell.db"
if [[ -f "$SPELL_DB" ]]; then
    install -m 644 "$SPELL_DB" "$DATADIR/spell.db"
    echo ">>> Installed: $DATADIR/spell.db"
else
    echo "note: $SPELL_DB missing — spell-check will be unavailable"
    echo "      build it with: bash apps/linux/scripts/prepare_spell_db.sh"
fi

sed -e "s|@BYK_EXEC@|$LIBDIR/byakaron-ibus|g" \
    -e "s|@BYK_ICON@|$ICONDIR/byakaron.svg|g" \
    -e "s|@BYK_SETUP@|$BYK_SETUP|g" \
    "$PROJECT_ROOT/Resources/byakaron.xml.in" > "$XMLDIR/byakaron.xml"
chmod 644 "$XMLDIR/byakaron.xml"
echo ">>> Installed: $XMLDIR/byakaron.xml"

# Fcitx5 is optional: same composer, different framework. Built only when the
# headers are present so a GNOME-only machine is not blocked on libfcitx5-dev.
# Only install if we rebuilt it this run — a leftover zig-out .so from an
# older day would otherwise overwrite a current engine with a stale addon.
FCITX_SO="$REPO_ROOT/zig-out/lib/fcitx5/byakaron.so"
FCITX_BUILT=0
if as_build_user "pkg-config --exists Fcitx5Core"; then
    echo ">>> Building the Fcitx5 addon${COMPAT_TARGET:+ ($COMPAT_TARGET)}..."
    if as_build_user "zig build linux-fcitx5 -Doptimize=ReleaseFast ${COMPAT_TARGET}"; then
        FCITX_BUILT=1
        byk_assert_glibc_20_04 "$FCITX_SO"
    fi
fi
if [[ "$FCITX_BUILT" -eq 1 && -f "$FCITX_SO" ]]; then
    FCITX_LIBDIR="$(pkg-config --variable=libdir Fcitx5Core 2>/dev/null || true)"
    if [[ -z "$FCITX_LIBDIR" ]]; then
        FCITX_LIBDIR="/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo x86_64-linux-gnu)"
    fi
    install -d "$FCITX_LIBDIR/fcitx5" \
        /usr/share/fcitx5/addon /usr/share/fcitx5/inputmethod
    install -m 755 "$FCITX_SO" "$FCITX_LIBDIR/fcitx5/byakaron.so"
    install -m 644 "$PROJECT_ROOT/Fcitx5/byakaron-addon.conf" \
        /usr/share/fcitx5/addon/byakaron.conf
    install -m 644 "$PROJECT_ROOT/Fcitx5/byakaron.conf" \
        /usr/share/fcitx5/inputmethod/byakaron.conf
    echo ">>> Installed: $FCITX_LIBDIR/fcitx5/byakaron.so"
    echo "    (Fcitx5 users add Byakaron in the Fcitx5 config tool; this does not switch the session IM)"
fi

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
echo "  2. Choose Bangla, then Byakaron (Bangla Phonetic) -> Add"
echo "  3. Switch with Super+Space"
echo "  (the first dialog is a language list — searching Byakaron there finds nothing)"
if [[ -n "$BYK_SETUP" ]]; then
    echo
    echo "The 'Byakaron' app is installed too — it walks through the steps above,"
    echo "types Bangla without switching input source, and checks spelling."
fi
