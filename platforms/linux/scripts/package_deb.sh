#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Build a shareable .deb of the Byakaron IBus engine.
#
#     bash platforms/linux/scripts/package_deb.sh
#
# Produces:  platforms/linux/build/byakaron_<version>_<arch>.deb
#
# The recipient does NOT need Zig, ziex, the source, or any -dev package.
# The engine binary links the Zig core statically; the only runtime
# dependencies are ibus + glib, which every GNOME/Ubuntu desktop already has.
# They install with:
#
#     sudo apt install ./byakaron_<version>_<arch>.deb
#
# and apt resolves the runtime dependencies automatically.
# ---------------------------------------------------------------------------

VERSION="${VERSION:-0.1.0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd)"

ARCH="$(dpkg --print-architecture)"
PKG="byakaron"
BUILD_DIR="$PROJECT_ROOT/build/deb"
STAGE="$BUILD_DIR/${PKG}_${VERSION}_${ARCH}"
OUT="$PROJECT_ROOT/build/${PKG}_${VERSION}_${ARCH}.deb"

# --- 1. Build the engine (ReleaseFast), unless a binary already exists ------
SRC_BIN="$REPO_ROOT/zig-out/bin/byakaron-ibus"
if [[ ! -x "$SRC_BIN" ]]; then
    echo ">>> Building byakaron-ibus (ReleaseFast)..."
    ( cd "$REPO_ROOT" && \
      PATH="$HOME/.local/bin:/usr/local/bin:$PATH" \
      zig build linux -Doptimize=ReleaseFast )
fi
[[ -x "$SRC_BIN" ]] || { echo "error: $SRC_BIN missing" >&2; exit 1; }

# The GTK app, if this box can build it. It is packaged when present rather
# than required, so the engine can still be shipped from a machine without
# libgtk-4-dev — and the .deb declares the gtk runtime dependency only then.
SRC_APP="$REPO_ROOT/zig-out/bin/byakaron"
if [[ ! -x "$SRC_APP" ]] && pkg-config --exists gtk4 libadwaita-1 2>/dev/null; then
    echo ">>> Building the GTK app (ReleaseFast)..."
    ( cd "$REPO_ROOT" && \
      PATH="$HOME/.local/bin:/usr/local/bin:$PATH" \
      zig build linux-app -Doptimize=ReleaseFast ) || true
fi

# --- 2. Assemble the package tree ------------------------------------------
rm -rf "$STAGE"
install -d "$STAGE/DEBIAN"
install -d "$STAGE/usr/libexec"
install -d "$STAGE/usr/bin"
install -d "$STAGE/usr/share/ibus/component"
install -d "$STAGE/usr/share/applications"
install -d "$STAGE/usr/share/icons/hicolor/scalable/apps"
install -d "$STAGE/usr/share/byakaron"

# Ship a stripped binary so the download is small (the built one carries
# debug_info and is ~14 MB; stripping roughly halves it).
install -m 755 "$SRC_BIN" "$STAGE/usr/libexec/byakaron-ibus"
strip --strip-unneeded "$STAGE/usr/libexec/byakaron-ibus" 2>/dev/null || true

install -m 644 "$PROJECT_ROOT/Resources/byakaron.svg" \
    "$STAGE/usr/share/icons/hicolor/scalable/apps/byakaron.svg"

BYK_SETUP=""
GTK_DEPENDS=""
if [[ -x "$SRC_APP" ]]; then
    install -m 755 "$SRC_APP" "$STAGE/usr/bin/byakaron"
    strip --strip-unneeded "$STAGE/usr/bin/byakaron" 2>/dev/null || true

    sed -e "s|@BYK_APP_EXEC@|/usr/bin/byakaron|g" \
        "$PROJECT_ROOT/Resources/byakaron-app.desktop.in" \
        > "$STAGE/usr/share/applications/byakaron.desktop"
    chmod 644 "$STAGE/usr/share/applications/byakaron.desktop"

    BYK_SETUP="/usr/bin/byakaron"
    GTK_DEPENDS=", libgtk-4-1, libadwaita-1-0"
    echo ">>> Packaged the GTK app"
else
    echo "note: $SRC_APP missing — the package will have the engine only"
    echo "      install libgtk-4-dev + libadwaita-1-dev to include the app"
fi

SPELL_DB="$REPO_ROOT/packages/data/spell.db"
if [[ -f "$SPELL_DB" ]]; then
    install -m 644 "$SPELL_DB" "$STAGE/usr/share/byakaron/spell.db"
else
    echo "note: $SPELL_DB missing — the package will have no spell-check"
    echo "      build it with: bash platforms/linux/scripts/prepare_spell_db.sh"
fi

sed -e "s|@BYK_EXEC@|/usr/libexec/byakaron-ibus|g" \
    -e "s|@BYK_ICON@|/usr/share/icons/hicolor/scalable/apps/byakaron.svg|g" \
    -e "s|@BYK_SETUP@|$BYK_SETUP|g" \
    "$PROJECT_ROOT/Resources/byakaron.xml.in" \
    > "$STAGE/usr/share/ibus/component/byakaron.xml"
chmod 644 "$STAGE/usr/share/ibus/component/byakaron.xml"

FCITX_SO="$REPO_ROOT/zig-out/lib/fcitx5/byakaron.so"
if [[ ! -f "$FCITX_SO" ]] && pkg-config --exists Fcitx5Core 2>/dev/null; then
    echo ">>> Building the Fcitx5 addon (ReleaseFast)..."
    ( cd "$REPO_ROOT" && \
      PATH="$HOME/.local/bin:/usr/local/bin:$PATH" \
      zig build linux-fcitx5 -Doptimize=ReleaseFast ) || true
fi
if [[ -f "$FCITX_SO" ]]; then
    FCITX_LIBDIR="$(pkg-config --variable=libdir Fcitx5Core 2>/dev/null || true)"
    if [[ -z "$FCITX_LIBDIR" ]]; then
        FCITX_LIBDIR="/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
    fi
    REL_LIB="${FCITX_LIBDIR#/}"
    install -d "$STAGE/${REL_LIB}/fcitx5" \
        "$STAGE/usr/share/fcitx5/addon" \
        "$STAGE/usr/share/fcitx5/inputmethod"
    install -m 755 "$FCITX_SO" "$STAGE/${REL_LIB}/fcitx5/byakaron.so"
    strip --strip-unneeded "$STAGE/${REL_LIB}/fcitx5/byakaron.so" 2>/dev/null || true
    install -m 644 "$PROJECT_ROOT/Fcitx5/byakaron-addon.conf" \
        "$STAGE/usr/share/fcitx5/addon/byakaron.conf"
    install -m 644 "$PROJECT_ROOT/Fcitx5/byakaron.conf" \
        "$STAGE/usr/share/fcitx5/inputmethod/byakaron.conf"
    echo ">>> Packaged the Fcitx5 addon"
fi

INSTALLED_KB="$(du -sk "$STAGE/usr" | cut -f1)"

# --- 3. Control metadata ---------------------------------------------------
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Architecture: $ARCH
Maintainer: Byakaron contributors <byakaron@example.com>
Installed-Size: $INSTALLED_KB
Depends: ibus (>= 1.5), libibus-1.0-5, libglib2.0-0t64 | libglib2.0-0$GTK_DEPENDS
Recommends: ibus-gtk4, ibus-gtk3
Suggests: fcitx5
Section: utils
Priority: optional
Homepage: https://github.com/nuhulabs/byakaron
Description: Byakaron Bangla phonetic input method (IBus engine)
 Type Bangla phonetically from a latin keyboard. Byakaron registers as a
 first-class input source in GNOME Settings -> Keyboard -> Input Sources and
 switches with Super+Space, powered by the shared Byakaron Zig engine.
 .
 Includes a GTK4 companion app for setup, composing Bangla without switching
 input source, and checking spelling.
EOF

# --- 4. Maintainer scripts: refresh the ibus registry ----------------------
# postinst / postrm run as root during apt, but the ibus daemon and its cache
# belong to the logged-in desktop user's session. Best-effort refresh each
# active graphical session; if none is reachable, a log out / in picks it up.
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/bash
set -e

refresh_ibus() {
    # Enumerate logged-in users with a running session bus and refresh each.
    for uid_dir in /run/user/*; do
        [ -S "$uid_dir/bus" ] || continue
        uid="$(basename "$uid_dir")"
        user="$(getent passwd "$uid" | cut -d: -f1)"
        [ -n "$user" ] || continue
        sudo -u "$user" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$uid_dir/bus" \
            ibus write-cache >/dev/null 2>&1 || true
        sudo -u "$user" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$uid_dir/bus" \
            ibus restart >/dev/null 2>&1 || true
    done
}

if [ "$1" = "configure" ]; then
    refresh_ibus
    echo ""
    echo "Byakaron installed. To start typing Bangla:"
    echo "  1. Settings -> Keyboard -> Input Sources -> '+'"
    echo "  2. Search 'Byakaron' (filed under Bangla), then Add"
    echo "  3. Switch with Super+Space"
    echo "  (If it does not appear yet, log out and back in.)"
fi

exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/bash
set -e

if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    for uid_dir in /run/user/*; do
        [ -S "$uid_dir/bus" ] || continue
        uid="$(basename "$uid_dir")"
        user="$(getent passwd "$uid" | cut -d: -f1)"
        [ -n "$user" ] || continue
        sudo -u "$user" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$uid_dir/bus" \
            ibus write-cache >/dev/null 2>&1 || true
        sudo -u "$user" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$uid_dir/bus" \
            ibus restart >/dev/null 2>&1 || true
    done
fi

exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postrm"

# --- 5. Build the .deb (force root:root ownership without needing sudo) -----
rm -f "$OUT"
dpkg-deb --root-owner-group --build "$STAGE" "$OUT"

echo
echo "=== Built: $OUT ==="
echo "    size: $(du -h "$OUT" | cut -f1)"
echo
echo "Share that one file. The recipient installs with:"
echo "    sudo apt install ./$(basename "$OUT")"
echo "and removes it with:"
echo "    sudo apt remove $PKG"
