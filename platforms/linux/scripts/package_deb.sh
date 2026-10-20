#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Build one shareable .deb of Byakaron.
#
#     bash platforms/linux/scripts/package_deb.sh
#
# Produces:
#     platforms/linux/build/byakaron_<version>_<arch>.deb
#         IBus engine + GTK app + GSettings schema + spell.db
#
# One file is a complete install: typing Bangla *and* spell-check. The
# recipient does NOT need Zig, ziex, the source, or any -dev package.
# The engine binary links the Zig core statically and is built for glibc 2.31
# (Ubuntu 20.04), so the keyboard runs on 20.04, 22.04, and 24.04.
#
# The GTK3 settings app is in this same package (Activities → Byakaron).
# GTK3 3.24 is on Ubuntu 20.04, 22.04, and 24.04, so Spelling /
# Layout / Setup run on all three.
#
# They install with:
#
#     sudo apt install ./byakaron_<version>_<arch>.deb
#
# Installing the .deb only registers the engine. They still have to add it:
# Settings → Keyboard → Input Sources → + → Bangla → Byakaron → Add,
# then Super+Space to switch. Or open the Byakaron app → Setup.
# ---------------------------------------------------------------------------

VERSION="${VERSION:-0.2.0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd)"

# shellcheck source=compat.sh
source "$SCRIPT_DIR/compat.sh"
COMPAT_TARGET="$(byk_compat_target_flag)"
if [[ -z "$COMPAT_TARGET" ]]; then
    echo "error: no glibc 2.31 Zig target for $(uname -m)" >&2
    exit 1
fi

if [[ $EUID -eq 0 ]]; then
    echo "error: do not run this as root — zig-out would become root-owned," >&2
    echo "       and the next non-root build would fail. Run:" >&2
    echo "         bash platforms/linux/scripts/package_deb.sh" >&2
    exit 1
fi

ARCH="$(dpkg --print-architecture)"
PKG="byakaron"
BUILD_DIR="$PROJECT_ROOT/build/deb"
STAGE="$BUILD_DIR/${PKG}_${VERSION}_${ARCH}"
OUT="$PROJECT_ROOT/build/${PKG}_${VERSION}_${ARCH}.deb"

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

# Always rebuild the engine against glibc 2.31 (Ubuntu 20.04). Skipping when
# zig-out/bin already exists is how a 24.04-only binary got shipped before.
#
# And from an empty cache: the shared .zig-cache missed a header-only edit
# (BYK_APP_VERSION in App/app.h), so 0.1.7 first packaged an app that still
# printed 0.1.6. A release costs a minute more; it never ships stale objects.
RELEASE_CACHE="$BUILD_DIR/zig-cache-release"
rm -rf "$RELEASE_CACHE"
echo ">>> Building byakaron-ibus (ReleaseFast, $COMPAT_TARGET, clean cache)..."
( cd "$REPO_ROOT" && zig build --cache-dir "$RELEASE_CACHE" linux -Doptimize=ReleaseFast $COMPAT_TARGET )
SRC_BIN="$REPO_ROOT/zig-out/bin/byakaron-ibus"
[[ -x "$SRC_BIN" ]] || { echo "error: $SRC_BIN missing" >&2; exit 1; }
byk_assert_glibc_20_04 "$SRC_BIN"

# The GTK3 app ships in the same package as the keyboard, targeted at glibc
# 2.31 so the UI runs on 20.04 / 22.04 / 24.04 like the engine.
SRC_APP="$REPO_ROOT/zig-out/bin/byakaron"
if pkg-config --exists gtk+-3.0 2>/dev/null; then
    echo ">>> Building the GTK3 app (ReleaseFast, $COMPAT_TARGET)..."
    # No `|| true`: a failed build would package whatever older binary is
    # still sitting in zig-out/bin.
    ( cd "$REPO_ROOT" && zig build --cache-dir "$RELEASE_CACHE" linux-app -Doptimize=ReleaseFast $COMPAT_TARGET )
    byk_assert_glibc_20_04 "$SRC_APP"
fi

# --- 2. Assemble the package tree ------------------------------------------
rm -rf "$STAGE"
install -d "$STAGE/DEBIAN"
install -d "$STAGE/usr/libexec"
install -d "$STAGE/usr/bin"
install -d "$STAGE/usr/share/ibus/component"
install -d "$STAGE/usr/share/applications"
install -d "$STAGE/usr/share/metainfo"
install -d "$STAGE/usr/share/icons/hicolor/scalable/apps"
install -d "$STAGE/usr/share/glib-2.0/schemas"

# Ship a stripped binary so the download is small (the built one carries
# debug_info and is ~14 MB; stripping roughly halves it).
install -m 755 "$SRC_BIN" "$STAGE/usr/libexec/byakaron-ibus"
strip --strip-unneeded "$STAGE/usr/libexec/byakaron-ibus" 2>/dev/null || true

install -m 644 "$PROJECT_ROOT/Resources/byakaron.svg" \
    "$STAGE/usr/share/icons/hicolor/scalable/apps/byakaron.svg"

install -m 644 "$PROJECT_ROOT/Resources/dev.nuhu.labs.Byakaron.gschema.xml" \
    "$STAGE/usr/share/glib-2.0/schemas/dev.nuhu.labs.Byakaron.gschema.xml"

BYK_SETUP=""
if [[ -x "$SRC_APP" ]]; then
    install -m 755 "$SRC_APP" "$STAGE/usr/bin/byakaron"
    strip --strip-unneeded "$STAGE/usr/bin/byakaron" 2>/dev/null || true

    sed -e "s|@BYK_APP_EXEC@|/usr/bin/byakaron|g" \
        "$PROJECT_ROOT/Resources/byakaron-app.desktop.in" \
        > "$STAGE/usr/share/applications/dev.nuhu.labs.Byakaron.desktop"
    chmod 644 "$STAGE/usr/share/applications/dev.nuhu.labs.Byakaron.desktop"
    install -m 644 "$PROJECT_ROOT/Resources/dev.nuhu.labs.Byakaron.metainfo.xml" \
        "$STAGE/usr/share/metainfo/dev.nuhu.labs.Byakaron.metainfo.xml"

    BYK_SETUP="/usr/bin/byakaron --page=setup"
    echo ">>> Packaged the GTK app (Spelling / Layout / Setup)"
else
    echo "note: $SRC_APP missing — the package will have the engine only"
    echo "      install libgtk-3-dev to include the app"
fi

SPELL_DB="$REPO_ROOT/packages/data/spell.db"
if [[ ! -f "$SPELL_DB" ]]; then
    echo ">>> spell.db missing — building it so the .deb is a complete install..."
    bash "$SCRIPT_DIR/prepare_spell_db.sh"
fi
[[ -f "$SPELL_DB" ]] || {
    echo "error: $SPELL_DB was not produced" >&2
    echo "       run: bash platforms/linux/scripts/prepare_spell_db.sh" >&2
    exit 1
}
install -d "$STAGE/usr/share/byakaron"
install -m 644 "$SPELL_DB" "$STAGE/usr/share/byakaron/spell.db"
echo ">>> Packaged spell.db ($(du -h "$SPELL_DB" | cut -f1))"

sed -e "s|@BYK_EXEC@|/usr/libexec/byakaron-ibus|g" \
    -e "s|@BYK_ICON@|/usr/share/icons/hicolor/scalable/apps/byakaron.svg|g" \
    -e "s|@BYK_SETUP@|$BYK_SETUP|g" \
    "$PROJECT_ROOT/Resources/byakaron.xml.in" \
    > "$STAGE/usr/share/ibus/component/byakaron.xml"
chmod 644 "$STAGE/usr/share/ibus/component/byakaron.xml"

# Only package Fcitx5 if we rebuilt it this run. A leftover zig-out .so from
# an older day would otherwise ship a stale addon next to a current engine.
FCITX_SO="$REPO_ROOT/zig-out/lib/fcitx5/byakaron.so"
FCITX_BUILT=0
if pkg-config --exists Fcitx5Core 2>/dev/null; then
    echo ">>> Building the Fcitx5 addon (ReleaseFast, $COMPAT_TARGET)..."
    if ( cd "$REPO_ROOT" && zig build --cache-dir "$RELEASE_CACHE" linux-fcitx5 -Doptimize=ReleaseFast $COMPAT_TARGET ); then
        FCITX_BUILT=1
        byk_assert_glibc_20_04 "$FCITX_SO"
    fi
fi
if [[ "$FCITX_BUILT" -eq 1 && -f "$FCITX_SO" ]]; then
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

if grep -R -n --include='*.xml' --include='*.desktop' '@BYK_' "$STAGE/usr" >/dev/null; then
    echo "error: unsubstituted @BYK_ placeholder in the staged package:" >&2
    grep -R -n --include='*.xml' --include='*.desktop' '@BYK_' "$STAGE/usr" >&2
    exit 1
fi
if [[ ! -f "$STAGE/usr/share/ibus/component/byakaron.xml" ]]; then
    echo "error: staged package is missing the IBus component XML" >&2
    exit 1
fi
[[ -f "$STAGE/usr/share/glib-2.0/schemas/dev.nuhu.labs.Byakaron.gschema.xml" ]] || {
    echo "error: staged package is missing the GSettings schema" >&2
    exit 1
}
if [[ -x "$SRC_APP" ]]; then
    for required in \
        "$STAGE/usr/bin/byakaron" \
        "$STAGE/usr/share/applications/dev.nuhu.labs.Byakaron.desktop" \
        "$STAGE/usr/share/metainfo/dev.nuhu.labs.Byakaron.metainfo.xml"
    do
        [[ -f "$required" ]] || { echo "error: missing $required" >&2; exit 1; }
    done
fi
[[ -f "$STAGE/usr/share/byakaron/spell.db" ]] || {
    echo "error: staged package is missing spell.db" >&2
    exit 1
}

# --- 3. Control metadata ---------------------------------------------------
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Architecture: $ARCH
Maintainer: Byakaron contributors <byakaron@example.com>
Installed-Size: $INSTALLED_KB
Depends: libc6 (>= 2.31), ibus (>= 1.5), libibus-1.0-5, libglib2.0-0t64 | libglib2.0-0, libgtk-3-0t64 | libgtk-3-0, libglib2.0-bin
Recommends: ibus-gtk3 | ibus-gtk, ibus-gtk4
Suggests: fcitx5
Replaces: byakaron-app, byakaron-data
Conflicts: byakaron-app, byakaron-data
Provides: byakaron-app, byakaron-data
Section: utils
Priority: optional
Homepage: https://nuhulabs.com/byakaron
Description: Bangla phonetic input method (IBus engine)
 Type Bangla phonetically from a latin keyboard. Registers as a
 first-class input source in GNOME Settings -> Keyboard -> Input Sources and
 switches with Super+Space, powered by the shared Byakaron Zig engine.
 .
 Includes a GTK3 companion app (Spelling, Layout, Setup) that runs on
 Ubuntu 20.04, 22.04, and 24.04, and the spell-check dictionary.
EOF

# --- 4. Maintainer scripts: refresh the ibus registry ----------------------
# postinst / postrm run as root during apt, but the ibus daemon and its cache
# belong to the logged-in desktop user's session. Best-effort refresh each
# active graphical session; if none is reachable, a log out / in picks it up.
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/bash
set -e

# apt runs this as root. The ibus daemon and its cache belong to each
# logged-in desktop session, so refresh those buses as the session user.
# runuser is in util-linux (essential); sudo is not a package dependency.
as_session_user() {
    local uid_dir="$1"
    shift
    local uid user
    uid="$(basename "$uid_dir")"
    user="$(getent passwd "$uid" | cut -d: -f1)"
    [ -n "$user" ] || return 0
    runuser -u "$user" -- env \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$uid_dir/bus" \
        "$@" >/dev/null 2>&1 || true
}

refresh_ibus() {
    for uid_dir in /run/user/*; do
        [ -S "$uid_dir/bus" ] || continue
        as_session_user "$uid_dir" ibus write-cache
        as_session_user "$uid_dir" ibus restart
    done
}

if [ "$1" = "configure" ]; then
    glib-compile-schemas /usr/share/glib-2.0/schemas >/dev/null 2>&1 || true
    update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
    gtk-update-icon-cache -qtf /usr/share/icons/hicolor >/dev/null 2>&1 || true
    refresh_ibus
    # $2 is the version being upgraded from, empty on a first install. An
    # upgrade keeps the input source the user already added, so the steps
    # would only be noise. The curl installer prints them itself and sets
    # BYAKARON_INSTALLER so they do not appear twice.
    if [ -n "$2" ]; then
        echo "Byakaron updated from $2. Your input source stays as it is."
    elif [ -z "${BYAKARON_INSTALLER:-}" ]; then
        echo ""
        echo "Byakaron installed. The package only registers the engine — add it:"
        if command -v gnome-control-center >/dev/null; then
            echo "  1. Settings -> Keyboard -> Input Sources -> '+'"
            echo "  2. Choose Bangla, then Byakaron (Bangla Phonetic) -> Add"
            echo "  3. Switch with Super+Space"
            echo "  If Byakaron is missing from the Bangla list, log out and back in."
        else
            echo "  1. As yourself: im-config -n ibus   (then log out and back in)"
            echo "  2. ibus-setup -> Input Method -> Add -> Bangla -> Byakaron"
            echo "  3. Switch with Super+Space"
        fi
        echo "  Or open the Byakaron app -> Setup, which walks through this."
    fi
fi

exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/bash
set -e

as_session_user() {
    local uid_dir="$1"
    shift
    local uid user
    uid="$(basename "$uid_dir")"
    user="$(getent passwd "$uid" | cut -d: -f1)"
    [ -n "$user" ] || return 0
    runuser -u "$user" -- env \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$uid_dir/bus" \
        "$@" >/dev/null 2>&1 || true
}

if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    glib-compile-schemas /usr/share/glib-2.0/schemas >/dev/null 2>&1 || true
    update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
    gtk-update-icon-cache -qtf /usr/share/icons/hicolor >/dev/null 2>&1 || true
    for uid_dir in /run/user/*; do
        [ -S "$uid_dir/bus" ] || continue
        as_session_user "$uid_dir" ibus write-cache
        as_session_user "$uid_dir" ibus restart
    done
fi

exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postrm"

# --- 5. Build the .deb (force root:root ownership without needing sudo) -----
rm -f "$OUT"
dpkg-deb --root-owner-group --build "$STAGE" "$OUT"

rm -f "$PROJECT_ROOT/build/${PKG}-data_${VERSION}_all.deb"

echo
echo "=== Built: $OUT ==="
echo "    size: $(du -h "$OUT" | cut -f1)"
echo
echo "Share this one file. It is a complete install (keyboard, app, spell-check)"
echo "on Ubuntu 20.04, 22.04, and 24.04. Do not use 'dpkg -i' — apt is what"
echo "installs ibus and GTK."
echo
echo "    sudo apt install ./$(basename "$OUT")"
echo
echo "Then they MUST add it (installing the package is not enough):"
echo "    Settings -> Keyboard -> Input Sources -> +"
echo "    Choose Bangla, then Byakaron (Bangla Phonetic) -> Add"
echo "    Super+Space to switch"
echo "    Or open the Byakaron app from Activities -> Setup"
echo
echo "If they previously installed an older byakaron / byakaron-data .deb:"
echo "    sudo apt remove byakaron byakaron-app byakaron-data"
echo "then install the new file. Remove with:"
echo "    sudo apt remove $PKG"
